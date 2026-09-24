import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var buddy: BuddyCursor!
    private var orchestrator: Orchestrator!
    private var panel: PromptPanel!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buddy = BuddyCursor()
        orchestrator = Orchestrator(buddy: buddy)
        panel = PromptPanel(orchestrator: orchestrator) { [weak self] in self?.panel.orderOut(nil) }
        // While acting, the panel must not be key or keystrokes would land in it instead of the target app.
        orchestrator.hidePanel = { [weak self] in self?.panel.orderOut(nil) }
        orchestrator.showPanel = { [weak self] in self?.panel.orderFrontRegardless() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "CursorBoy")

        let menu = NSMenu()
        menu.addItem(withTitle: "Open CursorBoy  (⌥Space)", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Check Permissions", action: #selector(checkPermissions), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu

        // Option+Space
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.togglePanel()
        }

        if !Permissions.allGranted {
            Permissions.requestMissing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.checkPermissions() }
        }
        if Config.typesafeKey == nil {
            NSLog("CursorBoy: TYPESAFE_API_KEY missing; fast clicks disabled")
        }
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        // Remember what the user was looking at; that's the app "click X" should act on.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            orchestrator.targetApp = front
        }
        panel.showCentered()
    }

    @objc func checkPermissions() {
        let lines = Permissions.all.map { item in
            "\(item.granted() ? "✅" : "❌")  \(item.name): \(item.why)"
        }
        let alert = NSAlert()
        alert.messageText = Permissions.allGranted ? "All permissions granted" : "CursorBoy needs these permissions"
        alert.informativeText = lines.joined(separator: "\n") + """


        Jev key: \(Config.typesafeKey == nil ? "❌ missing" : "✅ found")
        agy: \(Config.agyPath)

        After enabling something in System Settings, click Check Again. \
        Screen Recording may need CursorBoy to be restarted.
        """
        alert.addButton(withTitle: "Check Again")
        let missing = Permissions.all.first { !$0.granted() }
        if missing != nil {
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "Done")
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Permissions.requestMissing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.checkPermissions() }
        case .alertSecondButtonReturn:
            if let missing, let url = URL(string: missing.settingsURL) {
                missing.request()
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}
