import Foundation

/// Profiles discovered from Chromium preferences. Discovery never selects an unrelated last-used profile.
@MainActor
enum BrowserProfiles {
    private static let folders = [
        "com.google.Chrome": "Google/Chrome", "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
    ]

    struct Profile: Equatable {
        let directory: String
        let displayName: String
    }

    static func profilesWithExtension(_ browser: URL) -> [Profile] {
        guard let id = Bundle(url: browser)?.bundleIdentifier, let sub = folders[id] else { return [] }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(sub)")
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = state["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        return cache.keys.sorted().compactMap { name in
            guard !name.contains("/"), name != ".", name != ".." else { return nil }
            for file in ["Secure Preferences", "Preferences"] {
                guard let data = try? Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent(file)),
                      let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let extensions = prefs["extensions"] as? [String: Any],
                      let settings = extensions["settings"] as? [String: [String: Any]] else { continue }
                let found = settings.values.contains { setting in
                    guard (setting["state"] as? Int ?? 1) == 1 else { return false }
                    if let manifest = setting["manifest"] as? [String: Any], manifest["name"] as? String == "Clinqy",
                       let background = manifest["background"] as? [String: Any], background["service_worker"] as? String == "bridge.js" { return true }
                    // Unpacked extensions may omit a cached manifest. Inspect that path's manifest structurally.
                    guard let path = setting["path"] as? String, path.hasPrefix("/"),
                          let manifestData = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("manifest.json")),
                          let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                          manifest["name"] as? String == "Clinqy", let background = manifest["background"] as? [String: Any] else { return false }
                    return background["service_worker"] as? String == "bridge.js"
                }
                if found { return Profile(directory: name, displayName: cache[name]?["name"] as? String ?? name) }
            }
            return nil
        }
    }

    /// Returns only an unambiguous extension profile. The connected focused profile remains the runtime authority.
    static func withExtension(_ browser: URL) -> String? {
        let profiles = profilesWithExtension(browser)
        if profiles.count > 1 { Agent.writeLog("Multiple Clinqy browser profiles are available; choose the connected profile explicitly.") }
        return profiles.count == 1 ? profiles[0].directory : nil
    }
}
