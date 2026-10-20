import Foundation

/// A copy of the document a script is about to change, taken first: scripts that delete paragraphs have taken a
/// Word document's pictures with them, with nothing to go back to. Kept in ~/Pictures/Clinqy Backups (Documents is
/// privacy-protected).
enum DocBackup {
    /// Copies the front document of the app the script talks to (as last saved) and returns where. nil when the
    /// script names no app or its document has never been saved to a file.
    static func save(forScript script: String) async -> URL? {
        // A document the script opens itself is named in it: back that file up (nothing is open yet to ask about).
        let pattern = try? NSRegularExpression(pattern: #""((?:/|~/)[^"]+\.(?:docx?|pages|rtf|txt|xlsx?|numbers|pptx?|key|md))""#,
                                               options: .caseInsensitive)
        let named = (pattern?.matches(in: script, range: NSRange(script.startIndex..., in: script)) ?? [])
            .compactMap { Range($0.range(at: 1), in: script).map { URL(fileURLWithPath: (String(script[$0]) as NSString).expandingTildeInPath) } }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        if let named { return copy(named) }
        guard let r = script.range(of: #"(?i)tell application "([^"]+)""#, options: .regularExpression) else { return nil }
        let app = script[r].replacingOccurrences(of: #"(?i)tell application ""#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\"", with: "")
        // Word names it `full name of active document`; Pages, TextEdit, Keynote and Numbers `file of front document`.
        let asks = ["tell application \"\(app)\" to get POSIX path of (full name of active document as text)",
                    "tell application \"\(app)\" to get full name of active document",
                    "tell application \"\(app)\" to get POSIX path of (file of front document as alias)"]
        var path: String?
        for ask in asks {
            let out = await Shell.run("/usr/bin/osascript", ["-e", ask], timeout: 5)
            let p = out.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.status == 0, !p.isEmpty {
                path = p.hasPrefix("/") ? p : p.replacingOccurrences(of: ":", with: "/").replacingOccurrences(of: #"^[^/]+"#, with: "/Volumes/$0", options: .regularExpression)
                if let found = path, FileManager.default.fileExists(atPath: found) { break }
                path = nil
            }
        }
        guard let path else { return nil }
        return copy(URL(fileURLWithPath: path))
    }

    private static func copy(_ source: URL) -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Clinqy Backups")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) (before Clinqy \(stamp.string(from: Date()))).\(source.pathExtension)")
        do { try FileManager.default.copyItem(at: source, to: target); return target } catch { return nil }
    }
}
