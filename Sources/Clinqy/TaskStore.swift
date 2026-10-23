import Foundation
import Combine

/// Durable task state shared by the Mac UI and Telegram. Recovery never executes a stored request.
@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    enum State: String, Codable {
        case queued, running, waiting, needsAttention, interrupted, succeeded, failed, cancelled
        var terminal: Bool { [.interrupted, .succeeded, .failed, .cancelled].contains(self) }
        var label: String {
            switch self {
            case .needsAttention: return "Needs attention"
            default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
            }
        }
    }
    enum Source: String, Codable { case mac, telegram }
    struct Record: Codable, Identifiable, Equatable {
        var id = UUID()
        var request: String
        var files: [String]
        var source: Source
        var background: Bool
        var state: State = .queued
        var stage = "Queued"
        var completedSteps = 0
        var lastConfirmedStep: String?
        /// Written before an action starts, cleared only after it returns. Its contents contain no arguments/secrets.
        var pendingAction: String?
        var result: String?
        var createdAt = Date()
        var updatedAt = Date()
        var requiresReview = false
        var conversationID: Int64?
        var reviewReason: String?

        var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
        var status: String {
            var lines = ["\(state.label): \(request)", "Now: \(stage)", "\(completedSteps) steps completed"]
            if let lastConfirmedStep { lines.append("Last confirmed step: " + lastConfirmedStep) }
            if let pendingAction { lines.append("Outcome needs checking: " + pendingAction + ". It will not be replayed automatically.") }
            if let result { lines.append(result) }
            if requiresReview { lines.append(reviewReason ?? "Review this queued task before starting it after a restart.") }
            return lines.joined(separator: "\n")
        }
    }
    @Published private(set) var records: [Record] = []
    @Published private(set) var storageError: String?
    var onReady: ((UUID) -> Void)?
    private let file: URL
    private let redact: (String) -> String
    private var corrupt = false

    init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clinqy/tasks.json"),
         redact: @escaping (String) -> String = Secrets.mask) {
        self.file = file
        self.redact = redact
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: file))
            // A waiting question and any approval belong to the old process. Never reconstruct an active continuation.
            for index in records.indices {
                switch records[index].state {
                case .running, .waiting, .needsAttention:
                    records[index].state = .interrupted
                    records[index].stage = "Clinqy stopped before this task finished. Check the real outcome before sending new instructions."
                    records[index].updatedAt = Date()
                case .queued:
                    records[index].requiresReview = true
                    records[index].reviewReason = "Restored after restart. Review the request and files, then start it explicitly."
                default: break
                }
            }
            try save()
        } catch {
            corrupt = true
            storageError = "Task history couldn't be read safely. The existing file was preserved; automatic task starts are disabled."
        }
    }

    func record(_ id: UUID?) -> Record? { id.flatMap { id in records.first { $0.id == id } } }
    func find(_ shortID: String) -> Record? {
        let matches = records.filter { $0.id.uuidString.lowercased().hasPrefix(shortID.lowercased()) }
        return matches.count == 1 ? matches[0] : nil
    }
    var active: Record? { records.last { [.running, .waiting, .needsAttention].contains($0.state) } }
    var queued: [Record] { records.filter { $0.state == .queued }.sorted { $0.createdAt < $1.createdAt } }
    var recovery: [Record] { records.filter { $0.state == .interrupted || ($0.state == .queued && $0.requiresReview) } }

    @discardableResult
    func enqueue(_ request: String, files: [URL] = [], source: Source, background: Bool = true, conversationID: Int64? = nil) -> UUID? {
        let clean = redact(request)
        let item = Record(request: clean, files: files.map(\.path), source: source, background: background,
                          requiresReview: clean != request, conversationID: conversationID,
                          reviewReason: clean != request ? "Private values were removed from this request. Rewrite it without secrets before running it." : nil)
        guard mutate({ $0.append(item) }) else { return nil }
        return item.id
    }

    @discardableResult
    func start(_ id: UUID, explicitlyReviewed: Bool = false) -> Bool {
        guard let item = record(id), item.state == .queued, !item.requiresReview || explicitlyReviewed,
              item.reviewReason?.contains("Private values") != true, active == nil else { return false }
        guard item.files.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            update(id, state: .failed, stage: "An attached file is missing. Reattach it and send a new task.")
            return false
        }
        return change(id) { $0.state = .running; $0.stage = "Getting started"; $0.requiresReview = false; $0.reviewReason = nil }
    }

    @discardableResult
    func update(_ id: UUID?, state: State? = nil, stage: String? = nil, completedSteps: Int? = nil, background: Bool? = nil) -> Bool {
        guard let id, let item = record(id), !item.state.terminal else { return id == nil }
        return change(id) {
            if let state { $0.state = state }
            if let stage { $0.stage = redact(stage) }
            if let completedSteps { $0.completedSteps = completedSteps }
            if let background { $0.background = background }
        }
    }

    /// Must succeed before executing an action, otherwise fail closed instead of losing the recovery checkpoint.
    func beginAction(_ id: UUID?, kind: String) -> Bool {
        guard let id else { return true } // Unattended/test runs do not enter user history.
        guard let item = record(id), !item.state.terminal else { return false }
        return change(id) { $0.state = .running; $0.pendingAction = kind; $0.stage = "Working: " + kind }
    }
    func endAction(_ id: UUID?, kind: String, ok: Bool, completedSteps: Int) {
        guard let id, let item = record(id), !item.state.terminal else { return }
        _ = change(id) {
            $0.pendingAction = nil
            $0.completedSteps = completedSteps
            if ok { $0.lastConfirmedStep = kind }
        }
    }
    func finish(_ id: UUID?, ok: Bool, answer: String) {
        guard let id else { return }
        _ = change(id) {
            $0.state = answer == "Stopped" ? .cancelled : ok ? .succeeded : .failed
            $0.stage = redact(answer)
            $0.result = redact(answer)
            // Preserve an in-flight checkpoint when cancellation races with a side effect.
        }
    }
    func cancelQueued(_ id: UUID) {
        guard record(id)?.state == .queued else { return }
        _ = change(id) { $0.state = .cancelled; $0.stage = "Cancelled before starting" }
    }
    func requestStart(_ id: UUID) { guard record(id)?.state == .queued else { return }; onReady?(id) }

    private func change(_ id: UUID, _ action: (inout Record) -> Void) -> Bool {
        mutate { items in
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            action(&items[i]); items[i].updatedAt = Date()
        }
    }
    private func mutate(_ action: (inout [Record]) -> Void) -> Bool {
        guard !corrupt else { return false }
        let previous = records
        action(&records)
        do { try save(); storageError = nil; return true }
        catch { records = previous; storageError = "Couldn't save task state. Work is stopped to preserve safe recovery."; return false }
    }
    private func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(records)
        try data.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
