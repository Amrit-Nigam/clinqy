import Foundation

/// Whether Clinqy may post macOS notification banners. Pure so it can be unit-tested.
/// `stored`: the `notificationsEnabled` default (nil = never set = on). `env`: CLINQY_NOTIFICATIONS; a falsy value forces off.
enum NotificationPolicy {
    static let key = "notificationsEnabled"

    static func shouldPost(stored: Bool?, env: String?) -> Bool {
        if let env, ["0", "off", "no", "false"].contains(env.trimmingCharacters(in: .whitespaces).lowercased()) { return false }
        return stored ?? true
    }

    static var enabled: Bool {
        get { shouldPost(stored: UserDefaults.standard.object(forKey: key) as? Bool, env: ProcessInfo.processInfo.environment["CLINQY_NOTIFICATIONS"]) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
