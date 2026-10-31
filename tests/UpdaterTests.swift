import AppKit

enum Config { static func value(_ key: String) -> String? { nil } }
@MainActor enum Agent { static func writeLog(_ text: String) {} }
@main struct UpdaterTests {
    static func main() throws {
        precondition(Updater.isNewer("0.3.0", than: "0.2.3"))
        precondition(Updater.isNewer("0.10.0", than: "0.3.0"))
        precondition(!Updater.isNewer("0.3.0", than: "0.3"))
        precondition(!Updater.isNewer("0.2.3", than: "0.3.0"))
        let app = URL(fileURLWithPath: "build/Clinqy.app")
        let version = try String(contentsOfFile: "MAC_VERSION", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try Updater.validateApp(app, expectedVersion: version)
        do { try Updater.validateApp(app, expectedVersion: "99.99.99"); fatalError("wrong app version was accepted") } catch {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-update-validation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { try Updater.validateApp(root, expectedVersion: version); fatalError("unsigned app was accepted") } catch {}
        print("PASS updater version ordering, signed app acceptance, mismatched version and unsigned bundle rejection")
    }
}
