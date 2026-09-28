import AppKit

/// Moving structured data between places: tables pulled out of a web page, PDF or CSV (extract), and rows
/// written out as a CSV file, a Numbers document or the clipboard (table). The model does the mapping in
/// between; for a web form as the destination it types the values in itself.
enum Tables {
    /// A web page's tables (via the extension) as text the model can read: "Table 1 “Invoices” (12 rows)" + rows.
    static func describe(_ tables: [[String: Any]]) -> String {
        tables.enumerated().map { i, t in
            let rows = t["rows"] as? [[String]] ?? []
            let name = (t["name"] as? String).flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? ""
            let more = (t["more"] as? Int ?? 0) > 0 ? " (+\(t["more"] as? Int ?? 0) more rows not shown)" : ""
            let frame = (t["frame"] as? String).map { " [inside \(URL(string: $0)?.host ?? $0)]" } ?? ""
            return "Table \(i + 1) \(name)\(frame) — \(rows.count) rows\(more):\n" + rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Rows of a CSV/TSV file on disk.
    static func readDelimited(_ url: URL) -> [[String]]? {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return nil }
        let sep: Character = url.pathExtension.lowercased() == "tsv" || (!text.contains(",") && text.contains("\t")) ? "\t" : ","
        return parse(text, separator: sep)
    }

    /// A small RFC 4180 parser: quoted fields, doubled quotes, newlines inside quotes.
    static func parse(_ text: String, separator: Character = ",") -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" {
                row.append(field); field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else { field.append(c) }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { f in f.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f }
                .joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }

    /// Writes rows out. `to`: csv (a file), numbers (a new Numbers document), clipboard (tab-separated, pastes into
    /// any spreadsheet's cells). Returns a line for the agent.
    @MainActor
    static func save(_ rows: [[String]], to destination: String, path: String?, title: String?, append: Bool) async throws -> String {
        guard !rows.isEmpty, rows.contains(where: { !$0.isEmpty }) else { throw Pdf.Failure("no rows given") }
        let width = rows.map(\.count).max() ?? 0
        let rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        switch destination {
        case "clipboard", "paste":
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(rows.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t") }.joined(separator: "\n"), forType: .string)
            return "copied \(rows.count) rows × \(width) columns (tab-separated): click the first cell of a spreadsheet and press cmd+v"

        case "csv", "file", "numbers", "excel":
            let name = safeName(title ?? "Table")
            let wanted = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            var url = wanted ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(name).csv")
            if url.pathExtension.lowercased() != "csv" { url = url.appendingPathExtension("csv") }
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists, append {
                // Add to the end; skip the header row if the file already starts with the same one.
                let old = readDelimited(url) ?? []
                let add = old.first.map { $0 == rows.first ?? [] } == true ? Array(rows.dropFirst()) : rows
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(csv(add).utf8))
                if destination == "numbers", let app = numbersURL() {
                    _ = try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init())
                }
                return "appended \(add.count) rows to \(url.path) (now \(old.count + add.count) rows)"
            }
            if exists { url = Pdf.unique(url) }   // never overwrite
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try csv(rows).write(to: url, atomically: true, encoding: .utf8)
            if destination == "numbers" || destination == "excel" {
                let appName = destination == "numbers" ? "Numbers" : "Microsoft Excel"
                guard let app = destination == "numbers" ? numbersURL() : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Excel") else {
                    return "saved \(rows.count) rows to \(url.path) (\(appName) isn't installed, so it's a CSV file)"
                }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
                return "saved \(rows.count) rows to \(url.path) and opened it in \(appName) (it's now frontmost; save as a .\(destination == "numbers" ? "numbers" : "xlsx") file there if they want)"
            }
            return "saved \(rows.count) rows × \(width) columns to \(url.path)"

        default:
            throw Pdf.Failure("table to: csv, numbers, excel or clipboard (for a web form, type the values in)")
        }
    }

    private static func numbersURL() -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Numbers") }

    static func safeName(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Table" : cleaned).prefix(60))
    }
}
