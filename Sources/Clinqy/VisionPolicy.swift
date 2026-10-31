import Foundation

enum VisionPolicy {
    enum Mode: String { case auto, always, minimal }
    enum Delivery: String { case embedded, fileReference = "file_reference" }

    /// Explicit look is never suppressed. Auto pairs an initial image with semantics, then captures
    /// native transitions and browser document changes; ordinary DOM forms retain their fast path.
    static func capture(mode: Mode, explicit: Bool, first: Bool, native: Bool, changed: Bool,
                        documentChanged: Bool, knownElements: Int, failures: Int) -> Bool {
        if explicit || mode == .always { return true }
        if knownElements < 6 || failures >= 2 { return true }
        return mode == .auto && (first || documentChanged || (native && changed))
    }
}

/// A successful input or subprocess is not a completed user goal. A postcondition must be checked
/// after the latest potentially meaningful edit, including one which returned unverified delivery.
struct CompletionEvidence {
    private(set) var revision = 0
    private(set) var verifiedRevision = 0
    var needsVerification: Bool { revision != verifiedRevision }
    // Typed filesystem/EventKit tools already return their direct operation result; this gate covers
    // UI delivery, arbitrary scripts and generated artifacts, where delivery alone is weaker evidence.
    static let mutations: Set<String> = ["click", "right_click", "double_click", "drag", "type", "choose", "fill",
        "autofill", "upload", "key", "menu", "window", "shell", "applescript", "paste_snaps",
        "pdf", "table", "media"]
    mutating func record(kind: String, outcome: ActionOutcome, op: String = "") {
        let readOnlyOps: Set<String> = ["list", "find", "search", "info", "free", "busy", "check"]
        if Self.mutations.contains(kind), !readOnlyOps.contains(op), outcome.delivery != .notAttempted { revision += 1 }
        if kind == "verify", outcome.isConfirmed { verifiedRevision = revision }
    }
}

enum SavedFileEvidence {
    static func check(path: String, since: Date, contains expected: String? = nil) -> String? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0,
              let modified = values.contentModificationDate, modified >= since else { return nil }
        if let expected {
            guard !expected.isEmpty, size <= 10_000_000, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count <= 10_000_000, let text = String(data: data, encoding: .utf8), text.contains(expected) else { return nil }
            return "saved file has the expected contents: " + url.lastPathComponent
        }
        return "saved file exists and was modified during this run: " + url.lastPathComponent
    }
}
