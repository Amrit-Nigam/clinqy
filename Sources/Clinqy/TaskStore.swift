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
    /// What the user's request pinned down exactly. Kept apart from mutation freshness: a requirement stays open until
    /// evidence for that very requirement exists, however many unrelated verifications pass.
    struct Requirement: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case exactValue, name, setting, screenshot, caption, deliverable }
        var id = UUID()
        var kind: Kind
        var text: String
        var provenance: String
        var satisfied = false
        var evidence: String?
    }
    /// Outcomes, not gestures. Only explicit verification can complete a checklist entry.
    struct ChecklistItem: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var evidence: String?
        var verifiedAt: Date?
        var supersededAt: Date?
        var supersededReason: String?
        var complete: Bool { evidence != nil && verifiedAt != nil }
    }
    /// Redacted dispatch metadata. Arguments and entered text never enter the journal.
    struct ActionEntry: Codable, Equatable, Identifiable {
        enum State: String, Codable { case prepared, confirmed, unverified, unknown, rejected, resolved }
        var id: UUID
        var taskID: UUID
        var runID: String
        var kind: String
        var fingerprint: String
        var target: String
        var state: State
        var startedAt: Date
        var finishedAt: Date?
        var evidence: String?
    }
    /// Where an unresolved input happened, retained across continuation so the barrier survives a rebuilt run.
    struct PendingProvenance: Codable, Equatable {
        var kind: String
        var startedAt: Date
        var url: String?
        var tabID: Int?
        var visualOK: Bool
        var delivery: ActionOutcome.Delivery
    }
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
        /// A returned input whose application effect still needs independent readback.
        var unverifiedAction: String?
        var dispatchKey: String?
        var lastActionOutcome: ActionOutcome?
        var result: String?
        var createdAt = Date()
        var updatedAt = Date()
        var requiresReview = false
        var conversationID: Int64?
        var reviewReason: String?
        var coordinating: Bool?
        var parentID: UUID?
        var outputs: [String]?
        var requirements: [Requirement]?
        var pendingProvenance: PendingProvenance?
        var pendingActionID: UUID?
        var checklist: [ChecklistItem]?
        var phaseTimings: [String: Double]?
        var openChecklist: [ChecklistItem] { (checklist ?? []).filter { !$0.complete && $0.supersededAt == nil } }
        var openRequirements: [Requirement] { (requirements ?? []).filter { !$0.satisfied } }

        var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
        var status: String {
            var lines = ["\(state.label): \(request)", "Now: \(stage)", "\(completedSteps) steps completed"]
            if let lastConfirmedStep { lines.append("Last confirmed step: " + lastConfirmedStep) }
            if let pendingAction { lines.append("Outcome needs checking: " + pendingAction + ". It will not be replayed automatically.") }
            if let unverifiedAction { lines.append("Unverified outcome: " + unverifiedAction + ". Check the real state before retrying.") }
            if !openRequirements.isEmpty {
                lines.append("Still required: " + openRequirements.map { $0.kind.rawValue + " " + $0.text }.joined(separator: "; "))
            }
            if let checklist, !checklist.isEmpty {
                lines.append("Outcomes:\n" + checklist.map { ($0.supersededAt != nil ? "– " : $0.complete ? "✓ " : "○ ") + $0.id + ": " + $0.title }.joined(separator: "\n"))
            }
            if let result { lines.append(result) }
            if requiresReview { lines.append(reviewReason ?? "Review this queued task before starting it after a restart.") }
            return lines.joined(separator: "\n")
        }
    }
    @Published private(set) var records: [Record] = []
    @Published private(set) var storageError: String?
    var onReady: ((UUID) -> Void)?
    private let redact: (String) -> String
    private var database: SQLiteDatabase?
    private var positions: [UUID: Int] = [:]
    private var corrupt = false

    init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clinqy/tasks.sqlite"),
         legacyFile: URL? = nil, redact: @escaping (String) -> String = Secrets.mask) {
        self.redact = redact
        do {
            let db = try SQLiteDatabase(file: file)
            database = db
            try db.execute("CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY COLLATE NOCASE, state TEXT NOT NULL, updated REAL NOT NULL, payload TEXT NOT NULL); CREATE INDEX IF NOT EXISTS tasks_updated ON tasks(updated DESC); CREATE INDEX IF NOT EXISTS tasks_state ON tasks(state); CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);")
            try db.execute("CREATE TABLE IF NOT EXISTS action_journal(id TEXT PRIMARY KEY, task_id TEXT NOT NULL, state TEXT NOT NULL, started REAL NOT NULL, payload TEXT NOT NULL); CREATE INDEX IF NOT EXISTS action_journal_task ON action_journal(task_id, started);")
            let legacy = legacyFile ?? (file.lastPathComponent == "tasks.sqlite" ? file.deletingLastPathComponent().appendingPathComponent("tasks.json") : nil)
            if try db.rows("SELECT value FROM metadata WHERE key='legacy_imported'").isEmpty {
                try db.transaction {
                    if let legacy, FileManager.default.fileExists(atPath: legacy.path) {
                        let old = try JSONDecoder().decode([Record].self, from: Data(contentsOf: legacy))
                        for item in old { try persist(item, replace: false) }
                    }
                    try db.execute("INSERT INTO metadata VALUES('legacy_imported','1')")
                }
            }
            // Keep unfinished work and a recent UI window in memory. All older records remain addressable in SQL.
            let rows = try db.rows("SELECT payload FROM tasks WHERE state IN ('queued','running','waiting','needsAttention','interrupted') OR id IN (SELECT id FROM tasks ORDER BY updated DESC LIMIT 500) ORDER BY updated")
            records = try rows.map { try JSONDecoder().decode(Record.self, from: Data($0[0].utf8)) }
            try db.transaction {
                for index in records.indices {
                    switch records[index].state {
                    case .running, .waiting, .needsAttention:
                        // A process can die after dispatch but before acknowledgment. Recover every unfinished
                        // dispatch as unknown, never as a retryable failure or a successful action.
                        let unknown = try db.rows("SELECT payload FROM action_journal WHERE task_id=? AND state='prepared'", [records[index].id.uuidString])
                        for row in unknown {
                            var entry = try JSONDecoder().decode(ActionEntry.self, from: Data(row[0].utf8))
                            entry.state = .unknown
                            try persistEntry(entry, in: db)
                        }
                        if let pending = records[index].pendingAction {
                            records[index].unverifiedAction = records[index].unverifiedAction ?? pending
                            if records[index].pendingProvenance == nil {
                                records[index].pendingProvenance = PendingProvenance(kind: pending, startedAt: records[index].updatedAt,
                                    url: nil, tabID: nil, visualOK: false, delivery: .unknown)
                            }
                            records[index].pendingAction = nil
                        }
                        records[index].state = .interrupted
                        records[index].stage = "Clinqy stopped before this task finished. Check the real outcome before sending new instructions."
                        records[index].updatedAt = Date()
                        try persist(records[index])
                    case .queued:
                        records[index].requiresReview = true
                        records[index].reviewReason = "Restored after restart. Review the request and files, then start it explicitly."
                        try persist(records[index])
                    default: break
                    }
                }
            }
            // Retention only removes resolved history of terminal tasks; uncertain dispatches are never pruned.
            try db.execute("DELETE FROM action_journal WHERE state IN ('confirmed','rejected','resolved') AND task_id IN (SELECT id FROM tasks WHERE state IN ('succeeded','failed','cancelled')) AND (started < ? OR id IN (SELECT id FROM action_journal WHERE state IN ('confirmed','rejected','resolved') ORDER BY started DESC LIMIT -1 OFFSET 10000))", [String(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970)])
            rebuildPositions()
        } catch {
            corrupt = true
            storageError = "Task history couldn't be read safely. Existing files were preserved; automatic task starts are disabled."
        }
    }

    func record(_ id: UUID?) -> Record? {
        guard let id else { return nil }
        if let index = positions[id] { return records[index] }
        return stored("SELECT payload FROM tasks WHERE id=?", [id.uuidString]).first
    }
    func find(_ shortID: String) -> Record? {
        guard shortID.count >= 4, shortID.count <= 36, shortID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        let matches = stored("SELECT payload FROM tasks WHERE id LIKE ? LIMIT 2", [shortID + "%"])
        return matches.count == 1 ? matches[0] : nil
    }
    var backgroundLimit = 3
    var activeForeground: Record? { records.last { !$0.background && [.running, .waiting, .needsAttention].contains($0.state) } }
    var activeBackground: [Record] { records.filter { $0.background && $0.coordinating != true && [.running, .waiting, .needsAttention].contains($0.state) } }
    func coordinate(_ id: UUID) { _ = change(id) { $0.coordinating = true; $0.stage = "Waiting for parallel browser tasks" } }

    var active: Record? { records.last { [.running, .waiting, .needsAttention].contains($0.state) } }
    var queued: [Record] { records.filter { $0.state == .queued }.sorted { $0.createdAt < $1.createdAt } }
    var recovery: [Record] { records.filter { $0.state == .interrupted || ($0.state == .queued && $0.requiresReview) } }

    @discardableResult
    func enqueue(_ request: String, files: [URL] = [], source: Source, background: Bool = true, conversationID: Int64? = nil, idempotencyKey: String? = nil, parentID: UUID? = nil) -> UUID? {
        if let idempotencyKey {
            if let existing = records.first(where: { $0.dispatchKey == idempotencyKey }) { return existing.id }
            if let existing = stored("SELECT payload FROM tasks WHERE json_extract(payload, '$.dispatchKey')=? LIMIT 1", [idempotencyKey]).first { return existing.id }
        }
        let clean = redact(request)
        let item = Record(request: clean, files: files.map(\.path), source: source, background: background,
                          requiresReview: clean != request, conversationID: conversationID,
                          reviewReason: clean != request ? "Private values were removed from this request. Rewrite it without secrets before running it." : nil)
        var scheduled = item
        scheduled.dispatchKey = idempotencyKey
        scheduled.parentID = parentID
        guard !corrupt else { return nil }
        do { try persist(scheduled); records.append(scheduled); positions[scheduled.id] = records.count - 1; trimPublishedRecords(); storageError = nil }
        catch { storageError = "Couldn't save task state. Work is stopped to preserve safe recovery."; return nil }
        return item.id
    }

    @discardableResult
    func start(_ id: UUID, explicitlyReviewed: Bool = false) -> Bool {
        guard let item = record(id), item.state == .queued, !item.requiresReview || explicitlyReviewed,
              item.reviewReason?.contains("Private values") != true,
              TaskCapacity.canStart(background: item.background, foregroundRunning: activeForeground != nil,
                  backgroundRunning: activeBackground.count, limit: backgroundLimit) else { return false }
        guard item.files.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            update(id, state: .failed, stage: "An attached file is missing. Reattach it and send a new task.")
            return false
        }
        return change(id) { $0.state = .running; $0.stage = "Getting started"; $0.requiresReview = false; $0.reviewReason = nil }
    }

    /// Explicit user resumption keeps the same durable identity and uncertainty barrier. No old
    /// action is replayed: startup takes a fresh observation and requires evidence for unresolved input.
    @discardableResult
    func requestResume(_ id: UUID) -> Bool {
        guard let item = record(id), [.interrupted, .failed, .cancelled].contains(item.state),
              item.reviewReason?.contains("Private values") != true else { return false }
        guard change(id, { record in
            record.state = .queued
            record.stage = "Queued to inspect the existing outcome before continuing"
            record.requiresReview = false
            record.reviewReason = nil
            if let pending = record.pendingAction {
                record.unverifiedAction = record.unverifiedAction ?? pending
                if record.pendingProvenance == nil {
                    record.pendingProvenance = PendingProvenance(kind: pending, startedAt: record.updatedAt,
                        url: nil, tabID: nil, visualOK: false, delivery: .unknown)
                }
                record.pendingAction = nil
            }
        }) else { return false }
        onReady?(id)
        return true
    }

    /// Explicitly review a restored queued request without consuming a slot before it can run.
    @discardableResult
    func reviewQueued(_ id: UUID) -> Bool {
        guard let item = record(id), item.state == .queued,
              item.reviewReason?.contains("Private values") != true else { return false }
        return change(id) { $0.requiresReview = false; $0.reviewReason = nil }
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

    /// The task checkpoint and action reservation share one durable transaction. Reusing an ID is
    /// refused even if its previous result was lost; the caller must observe instead of dispatching again.
    func beginAction(_ id: UUID?, kind: String, actionID: UUID = UUID(), runID: String = "legacy",
                     fingerprint: String = "", target: String = "", mutation: Bool = true,
                     provenance: PendingProvenance? = nil) -> Bool {
        guard let id else { return true }
        guard let item = record(id), !item.state.terminal,
              !mutation || (item.pendingAction == nil && item.unverifiedAction == nil) else { return false }
        let entry = ActionEntry(id: actionID, taskID: id, runID: runID, kind: kind,
            fingerprint: fingerprint, target: target, state: .prepared, startedAt: Date())
        return change(id, journal: mutation ? { db in
            guard try db.rows("SELECT id FROM action_journal WHERE id=?", [actionID.uuidString]).isEmpty else {
                throw NSError(domain: "Clinqy.Actions", code: 1, userInfo: [NSLocalizedDescriptionKey: "Action already reserved"])
            }
            try self.persistEntry(entry, in: db)
        } : nil) {
            $0.state = .running
            if mutation {
                $0.pendingAction = kind; $0.pendingActionID = actionID
                if $0.unverifiedAction == nil { $0.pendingProvenance = provenance }
            }
            $0.stage = "Working: " + kind
        }
    }
    @discardableResult
    func endAction(_ id: UUID?, kind: String, outcome: ActionOutcome, completedSteps: Int,
                   provenance: PendingProvenance? = nil, actionID: UUID? = nil) -> Bool {
        guard let id else { return true }
        guard let item = record(id), !item.state.terminal else { return false }
        // Legacy callers omit the dispatch ID. A readback must never borrow the reservation of
        // an earlier uncertain mutation merely because that reservation is still pending.
        let ticket = actionID ?? (item.pendingAction == kind ? item.pendingActionID : nil)
        return change(id, journal: { db in
            if let ticket, let row = try db.rows("SELECT payload FROM action_journal WHERE id=? AND task_id=?", [ticket.uuidString, id.uuidString]).first {
                var entry = try JSONDecoder().decode(ActionEntry.self, from: Data(row[0].utf8))
                entry.state = outcome.isConfirmed ? .confirmed : outcome.delivery == .unknown ? .unknown : outcome.needsVerification ? .unverified : .rejected
                entry.finishedAt = Date()
                try self.persistEntry(entry, in: db)
            }
        }) {
            if (actionID == nil && $0.pendingAction == kind) || (actionID != nil && $0.pendingActionID == actionID) { $0.pendingAction = nil }
            $0.completedSteps = completedSteps
            $0.lastActionOutcome = outcome
            if outcome.isConfirmed { $0.lastConfirmedStep = kind }
            if outcome.needsVerification { $0.unverifiedAction = kind; $0.pendingProvenance = provenance; $0.pendingActionID = ticket }
            else if $0.unverifiedAction == nil, $0.pendingActionID == ticket { $0.pendingActionID = nil; $0.pendingProvenance = nil }
        }
    }
    func actionHistory(_ id: UUID, limit: Int = 100) -> [ActionEntry] {
        guard let rows = try? database?.rows("SELECT payload FROM action_journal WHERE task_id=? ORDER BY started DESC LIMIT ?", [id.uuidString, String(min(500, max(1, limit)))]) else { return [] }
        return rows.compactMap { try? JSONDecoder().decode(ActionEntry.self, from: Data($0[0].utf8)) }
    }
    private func persistEntry(_ entry: ActionEntry, in db: SQLiteDatabase) throws {
        let payload = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        try db.execute("INSERT INTO action_journal VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,payload=excluded.payload",
            [entry.id.uuidString, entry.taskID.uuidString, entry.state.rawValue, String(entry.startedAt.timeIntervalSince1970), payload])
    }
    private func resolveJournal(_ id: UUID, evidence: String, confirmed: Bool, in db: SQLiteDatabase) throws {
        // Resolve only this task's latest unresolved dispatch. Older uncertain entries remain auditable.
        guard let ticket = record(id)?.pendingActionID,
              let row = try db.rows("SELECT payload FROM action_journal WHERE id=? AND task_id=?", [ticket.uuidString, id.uuidString]).first else { return }
        var entry = try JSONDecoder().decode(ActionEntry.self, from: Data(row[0].utf8))
        entry.state = confirmed ? .confirmed : .resolved
        entry.evidence = redact(evidence); entry.finishedAt = Date()
        try persistEntry(entry, in: db)
    }
    /// Only a successful, explicit state assertion resolves an uncertain side effect.
    @discardableResult
    func confirmAction(_ id: UUID?, evidence: String) -> Bool {
        guard let id else { return true }
        guard let item = record(id), !item.state.terminal else { return false }
        return change(id, journal: { try self.resolveJournal(id, evidence: evidence, confirmed: true, in: $0) }) {
            if let action = $0.unverifiedAction { $0.lastConfirmedStep = action + " (" + redact(evidence) + ")" }
            $0.unverifiedAction = nil
            $0.pendingProvenance = nil
            $0.pendingActionID = nil
        }
    }
    /// The user (or another explicit non-evidence route) reports that the uncertain effect did not happen: the barrier
    /// is lifted without claiming a confirmed step.
    @discardableResult
    func resolveAction(_ id: UUID?, evidence: String) -> Bool {
        guard let id else { return true }
        guard let item = record(id), !item.state.terminal else { return false }
        return change(id, journal: { try self.resolveJournal(id, evidence: evidence, confirmed: false, in: $0) }) {
            $0.pendingActionID = nil
            $0.stage = redact(evidence)
            $0.unverifiedAction = nil
            $0.pendingProvenance = nil
        }
    }

    // MARK: Outcome checklist

    /// Plans are additive: a later model turn cannot erase unfinished outcomes to make completion pass.
    func addChecklist(_ id: UUID?, titles: [String]) -> Bool {
        guard let id else { return true }
        guard let item = record(id), !item.state.terminal else { return false }
        var list = item.checklist ?? []
        for title in titles {
            let clean = redact(title.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !clean.isEmpty, clean.utf8.count <= 500 else { return false }
            if !list.contains(where: { $0.title == clean }) {
                guard list.count < 32 else { return false }
                list.append(ChecklistItem(id: "s\(list.count + 1)", title: clean))
            }
        }
        return change(id) { $0.checklist = list }
    }
    func verifyChecklist(_ id: UUID?, step: String, evidence: String) -> Bool {
        guard let id else { return true }
        guard let item = record(id), !item.state.terminal,
              let index = item.checklist?.firstIndex(where: { $0.id == step && $0.supersededAt == nil }),
              !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return change(id) { $0.checklist?[index].evidence = redact(evidence); $0.checklist?[index].verifiedAt = Date() }
    }
    func supersedeChecklist(_ id: UUID?, ids: [String], reason: String) -> Bool {
        guard !ids.isEmpty, let id else { return true }
        guard let item = record(id), !item.state.terminal else { return false }
        return change(id) {
            guard var list = $0.checklist else { return }
            for index in list.indices where ids.contains(list[index].id) {
                list[index].supersededAt = Date(); list[index].supersededReason = redact(reason)
            }
            $0.checklist = list
        }
    }
    func setTimings(_ id: UUID?, milliseconds: [String: Double]) {
        guard let id else { return }
        _ = change(id) { $0.phaseTimings = milliseconds.filter { $0.value.isFinite && $0.value >= 0 } }
    }

    // MARK: Requirements ledger

    /// Adds requirements once (same kind and text are not duplicated). Returns false when the record can't be saved.
    @discardableResult
    func addRequirements(_ id: UUID?, _ items: [(Requirement.Kind, String)], provenance: String) -> Bool {
        guard let id else { return true }
        guard let item = record(id), !item.state.terminal else { return false }
        let existing = item.requirements ?? []
        let fresh = items.filter { kind, text in !existing.contains { $0.kind == kind && $0.text == redact(text) } }
        guard !fresh.isEmpty else { return true }
        return change(id) {
            $0.requirements = existing + fresh.map { Requirement(kind: $0.0, text: redact($0.1), provenance: provenance) }
        }
    }
    /// Marks every open requirement of `kind` (optionally only the one matching `text`) as met by `evidence`.
    @discardableResult
    func satisfyRequirement(_ id: UUID?, kind: Requirement.Kind, matching text: String? = nil, evidence: String) -> Bool {
        guard let id else { return true }
        guard let item = record(id), let list = item.requirements,
              list.contains(where: { !$0.satisfied && $0.kind == kind && (text == nil || $0.text == redact(text!)) }) else { return true }
        return change(id) {
            guard var all = $0.requirements else { return }
            for index in all.indices where !all[index].satisfied && all[index].kind == kind && (text == nil || all[index].text == redact(text!)) {
                all[index].satisfied = true; all[index].evidence = redact(evidence)
            }
            $0.requirements = all
        }
    }
    /// File evidence resolves only the normalized path it actually inspected.
    @discardableResult
    func satisfyDeliverable(_ id: UUID?, path: String, evidence: String) -> Bool {
        guard let id else { return true }
        func normalized(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard let item = record(id) else { return false }
        let target = normalized(path)
        let matches = (item.requirements ?? []).filter {
            !$0.satisfied && $0.kind == .deliverable && ($0.text.hasPrefix("/") || $0.text.hasPrefix("~")) && normalized($0.text) == target
        }.map(\.id)
        guard !matches.isEmpty else { return true }
        return change(id) {
            guard var requirements = $0.requirements else { return }
            for index in requirements.indices where matches.contains(requirements[index].id) {
                requirements[index].satisfied = true
                requirements[index].evidence = redact(evidence)
            }
            $0.requirements = requirements
        }
    }
    func setOutputs(_ id: UUID?, files: [URL]) {
        guard let id else { return }
        _ = change(id) { $0.outputs = files.map(\.path) }
    }
    @discardableResult
    func finish(_ id: UUID?, ok: Bool, answer: String) -> Bool {
        guard let id else { return true }
        return change(id, journal: { db in
            for row in try db.rows("SELECT payload FROM action_journal WHERE task_id=? AND state='prepared'", [id.uuidString]) {
                var entry = try JSONDecoder().decode(ActionEntry.self, from: Data(row[0].utf8))
                entry.state = .unknown; entry.finishedAt = Date()
                try self.persistEntry(entry, in: db)
            }
        }) {
            let missingDeliverable = $0.openRequirements.contains { $0.kind == .deliverable && ($0.text.hasPrefix("/") || $0.text.hasPrefix("~")) }
            $0.state = answer == "Stopped" ? .cancelled : ok && $0.pendingAction == nil && $0.unverifiedAction == nil && $0.openChecklist.isEmpty && !missingDeliverable ? .succeeded : .failed
            let checked = ok && ($0.pendingAction != nil || $0.unverifiedAction != nil || !$0.openChecklist.isEmpty || missingDeliverable)
                ? "Outcome not confirmed. Check the remaining task outcomes before retrying. " + answer : answer
            $0.stage = redact(checked)
            $0.result = redact(checked)
            // Preserve an in-flight checkpoint when cancellation races with a side effect.
        }
    }
    func cancelQueued(_ id: UUID) {
        guard record(id)?.state == .queued else { return }
        _ = change(id) { $0.state = .cancelled; $0.stage = "Cancelled before starting" }
    }
    func requestStart(_ id: UUID) { guard record(id)?.state == .queued else { return }; onReady?(id) }

    private func change(_ id: UUID, journal: ((SQLiteDatabase) throws -> Void)? = nil, _ action: (inout Record) -> Void) -> Bool {
        guard !corrupt, var item = record(id) else { return false }
        action(&item); item.updatedAt = Date()
        do {
            if let journal, let database {
                try database.transaction { try journal(database); try persist(item) }
            } else { try persist(item) }
            // Durable acknowledgment comes before publishing or executing a side effect.
            if let index = positions[id] { records[index] = item }
            else { records.append(item); positions[id] = records.count - 1 }
            trimPublishedRecords()
            storageError = nil
            return true
        } catch {
            storageError = "Couldn't save task state. Work is stopped to preserve safe recovery."
            return false
        }
    }

    private func persist(_ item: Record, replace: Bool = true) throws {
        guard let database else { throw NSError(domain: "Clinqy.Tasks", code: 1) }
        let payload = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        let sql = replace
            ? "INSERT INTO tasks VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,updated=excluded.updated,payload=excluded.payload"
            : "INSERT OR IGNORE INTO tasks VALUES(?,?,?,?)"
        try database.execute(sql, [item.id.uuidString, item.state.rawValue, String(item.updatedAt.timeIntervalSince1970), payload])
    }
    private func stored(_ sql: String, _ values: [String]) -> [Record] {
        guard let rows = try? database?.rows(sql, values) else { return [] }
        return rows.compactMap { try? JSONDecoder().decode(Record.self, from: Data($0[0].utf8)) }
    }
    private func trimPublishedRecords() {
        guard records.count > 600 else { return }
        let recent = Set(records.suffix(500).map(\.id))
        records.removeAll { $0.state.terminal && $0.state != .interrupted && !recent.contains($0.id) }
        rebuildPositions()
    }
    private func rebuildPositions() { positions = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) }) }
}

/// Pulls the exact constraints out of a request so they outlive the model's context: quoted values, requested
/// screenshots and captions, and the identity of the deliverable. Conservative by design: only literal text is kept.
enum RequirementExtractor {
    static func extract(_ request: String) -> [(TaskStore.Requirement.Kind, String)] {
        let text = request.components(separatedBy: "\n\nPrevious Telegram task").first ?? request
        var found: [(TaskStore.Requirement.Kind, String)] = []
        func add(_ kind: TaskStore.Requirement.Kind, _ value: String) {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 300, !found.contains(where: { $0.0 == kind && $0.1 == clean }) else { return }
            found.append((kind, clean))
        }
        func matches(_ pattern: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
                (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            }
        }
        for m in matches(#"["“]([^"”\n]{1,200})["”]"#) { add(.exactValue, m[1]) }
        for m in matches(#"\b(?:named|called|titled)\s+(?:it\s+)?["“]?([A-Za-z0-9][^"”\n,;]{0,80}?)["”]?(?=[,.;\n]|\s+(?:and|with|in|on|to|then)\b|$)"#) { add(.name, m[1]) }
        for m in matches(#"(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:separate\s+)?(?:screenshots?|screen\s*shots?|screen\s*captures?)"#) { add(.screenshot, m[1] + " screenshot(s)") }
        if text.range(of: #"(?i)\bcaptions?\b"#, options: .regularExpression) != nil { add(.caption, "every requested screenshot carries its caption") }
        for m in matches(#"((?:~|/Users/[^\s/]+)/[^\s"”,;]*\.[A-Za-z0-9]{1,6})"#) { add(.deliverable, m[1]) }
        if TaskCompletionPolicy.requestsWriteUp(text) { add(.deliverable, "write-up document") }
        return found
    }
}
