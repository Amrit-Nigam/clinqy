import Foundation

/// Profiles of Chromium browsers (Chrome, Brave, Edge), read from their own settings files.
@MainActor
enum BrowserProfiles {
    private static let folders = [
        "com.google.Chrome": "Google/Chrome", "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
    ]

    /// The profile folder ("Default", "Profile 2"…) that has Clinqy's extension loaded, else the one used last;
    /// nil for a browser without profiles to pick.
    static func withExtension(_ browser: URL) -> String? {
        guard let id = Bundle(url: browser)?.bundleIdentifier, let sub = folders[id] else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(sub)")
        let data: Data
        do { data = try Data(contentsOf: root.appendingPathComponent("Local State")) } catch {
            Agent.writeLog("    couldn't read \(sub)'s profiles: \(error.localizedDescription)")
            return nil
        }
        guard let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = state["profile"] as? [String: Any] else { return nil }
        let names = ((profile["info_cache"] as? [String: Any])?.keys).map(Array.init) ?? []
        for name in names.sorted() {
            for file in ["Secure Preferences", "Preferences"] {
                guard let text = try? String(contentsOf: root.appendingPathComponent("\(name)/\(file)"), encoding: .utf8) else { continue }
                if text.contains("Clinqy/extension") || text.contains("Clinqy\\/extension") { return name }
            }
        }
        return profile["last_used"] as? String
    }
}
