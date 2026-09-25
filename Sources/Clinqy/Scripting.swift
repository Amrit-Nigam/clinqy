import AppKit
import Carbon

/// AppleScript dictionaries (sdef) of scriptable apps, condensed so the agent can script an app directly
/// when clicking fails or the user asks for speed.
enum Scripting {
    private static var cache: [String: String] = [:]

    /// True if the app publishes an AppleScript dictionary.
    static func isScriptable(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL, let info = Bundle(url: url)?.infoDictionary else { return false }
        return info["OSAScriptingDefinition"] != nil || (info["NSAppleScriptEnabled"] as? Bool ?? false)
            || (info["NSAppleScriptEnabled"] as? String) == "YES"
    }

    /// A compact summary of the app's dictionary: its own commands and its classes with properties and elements.
    static func dictionary(for app: NSRunningApplication) async -> String? {
        guard let url = app.bundleURL else { return nil }
        let key = app.bundleIdentifier ?? url.path
        if let cached = cache[key] { return cached }
        // The system's own reader (the `sdef` tool needs full Xcode).
        var raw: Unmanaged<CFData>?
        guard OSACopyScriptingDefinitionFromURL(url as CFURL, 0, &raw) == noErr, let cf = raw?.takeRetainedValue(),
              let doc = try? XMLDocument(data: cf as Data, options: [.documentXInclude]) else { return nil }
        var lines: [String] = []
        // Standard/Text suites are the same everywhere; the app's own suites are what matter.
        let boring: Set<String> = ["Standard Suite", "Text Suite", "Type Definitions", "Type Names Suite"]
        for suite in (try? doc.nodes(forXPath: "//suite")) as? [XMLElement] ?? [] {
            let suiteName = suite.attribute(forName: "name")?.stringValue ?? ""
            let standard = boring.contains(suiteName)
            let commands = ((try? suite.nodes(forXPath: "command")) as? [XMLElement] ?? [])
                .compactMap { cmd -> String? in
                    guard let name = cmd.attribute(forName: "name")?.stringValue else { return nil }
                    if standard && !["make", "delete", "open", "close", "save", "count", "exists", "move", "duplicate"].contains(name) { return nil }
                    let params = ((try? cmd.nodes(forXPath: "parameter")) as? [XMLElement] ?? [])
                        .compactMap { $0.attribute(forName: "name")?.stringValue }
                    return params.isEmpty ? name : "\(name) (\(params.joined(separator: ", ")))"
                }
            if !commands.isEmpty { lines.append("commands: " + commands.joined(separator: "; ")) }
            if standard { continue }
            for cls in (try? suite.nodes(forXPath: "class | class-extension")) as? [XMLElement] ?? [] {
                let name = cls.attribute(forName: "name")?.stringValue ?? cls.attribute(forName: "extends")?.stringValue ?? "?"
                let props = ((try? cls.nodes(forXPath: "property")) as? [XMLElement] ?? [])
                    .compactMap { p -> String? in
                        guard let n = p.attribute(forName: "name")?.stringValue else { return nil }
                        return p.attribute(forName: "access")?.stringValue == "r" ? "\(n)(ro)" : n
                    }
                let elements = ((try? cls.nodes(forXPath: "element")) as? [XMLElement] ?? [])
                    .compactMap { $0.attribute(forName: "type")?.stringValue }
                var line = "class \(name)"
                if !props.isEmpty { line += " — props: " + props.prefix(18).joined(separator: ", ") }
                if !elements.isEmpty { line += " — contains: " + elements.joined(separator: ", ") }
                lines.append(line)
            }
        }
        guard !lines.isEmpty else { return nil }
        let text = "AppleScript dictionary of \(app.cleanName ?? "the app") (tell application \"\(app.cleanName ?? "")\"):\n"
            + lines.joined(separator: "\n")
        let trimmed = String(text.prefix(6000))
        cache[key] = trimmed
        return trimmed
    }
}
