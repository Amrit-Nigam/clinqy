import AppKit

/// Keeps Clinqy for Mac up to date from its GitHub releases. Mac releases are tagged `mac-v<version>` and carry
/// `Clinqy.dmg` (the repo's "latest" release is the Windows one, so this reads the list rather than /latest).
/// Checks a minute after launch and then once a day; a newer version shows in the menu bar menu and asks once.
/// Installing downloads the disk image, swaps the app in /Applications, and reopens it. Settings, memory and
/// history live outside the app, so they're kept. UPDATE_CHECK=off in ~/.config/clinqy/env turns the checks off.
@MainActor
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let dmg: URL
        let page: URL
        let notes: String
    }

    private(set) var available: Release?
    /// Called when `available` changes (the app delegate updates its menu item).
    var onChange: () -> Void = {}
    private var timer: Timer?
    private var initialCheck: Task<Void, Never>?
    private var scheduledCheck: Task<Void, Never>?
    private var checking = false
    /// Supplied by the app; updates never interrupt an active foreground or background task.
    var isBusy: () -> Bool = { false }
    private(set) var installing = false

    nonisolated static let repo = "Amrit-Nigam/clinqy"

    /// This copy's version (CLINQY_VERSION overrides it, for testing the updater).
    nonisolated static var current: String {
        ProcessInfo.processInfo.environment["CLINQY_VERSION"]
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Whether `a` is a newer version than `b` (dot-separated numbers).
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// The newest published Mac release, from the GitHub API.
    nonisolated static func newestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=100")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Clinqy/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "Clinqy", code: 1, userInfo: [NSLocalizedDescriptionKey: "GitHub didn't answer (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"])
        }
        var best: Release?
        for r in list where r["draft"] as? Bool != true && r["prerelease"] as? Bool != true {
            guard let tag = r["tag_name"] as? String, tag.hasPrefix("mac-v"),
                  let assets = r["assets"] as? [[String: Any]],
                  let dmg = assets.first(where: { ($0["name"] as? String) == "Clinqy.dmg" })?["browser_download_url"] as? String,
                  let dmgURL = URL(string: dmg), let page = (r["html_url"] as? String).flatMap(URL.init(string:)) else { continue }
            let version = String(tag.dropFirst("mac-v".count))
            if best == nil || isNewer(version, than: best!.version) {
                best = Release(version: version, dmg: dmgURL, page: page, notes: r["body"] as? String ?? "")
            }
        }
        return best
    }

    /// Starts the background checks (a minute after launch, then daily).
    func start() {
        guard timer == nil, Config.value("UPDATE_CHECK")?.lowercased() != "off" else { return }
        initialCheck = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.check(userAsked: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledCheck?.cancel()
                self.scheduledCheck = Task { [weak self] in await self?.check(userAsked: false) }
            }
        }
        timer?.tolerance = 300
    }

    func stop() {
        timer?.invalidate(); timer = nil
        initialCheck?.cancel(); initialCheck = nil
        scheduledCheck?.cancel(); scheduledCheck = nil
    }

    /// Looks for a newer version. When the user asked (the menu item), always says what it found.
    func check(userAsked: Bool) async {
        guard !checking, !installing, !Task.isCancelled else { return }
        checking = true
        defer { checking = false }
        do {
            let newest = try await Self.newestRelease()
            guard !Task.isCancelled else { return }
            if let newest, Self.isNewer(newest.version, than: Self.current) {
                available = newest
                onChange()
                Agent.writeLog("update: \(newest.version) is out (this is \(Self.current))")
                let askedKey = "updateOffered"
                if !isBusy(), userAsked || UserDefaults.standard.string(forKey: askedKey) != newest.version {
                    UserDefaults.standard.set(newest.version, forKey: askedKey)
                    offer(newest)
                }
            } else {
                available = nil
                onChange()
                if userAsked { info("Clinqy is up to date", "You have the newest version, \(Self.current).") }
            }
        } catch {
            if userAsked, !Task.isCancelled { info("Couldn't check for updates", error.localizedDescription) }
        }
    }

    private func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Asks whether to install `release` now.
    func offer(_ release: Release) {
        guard !isBusy() else { return }
        let alert = NSAlert()
        alert.messageText = "Clinqy \(release.version) is available"
        let notes = release.notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }.prefix(5).joined(separator: "\n")
        alert.informativeText = "You have \(Self.current). Installing takes a few seconds and Clinqy reopens by itself; "
            + "your settings, memory and history are kept." + (notes.isEmpty ? "" : "\n\nNew:\n" + notes.replacingOccurrences(of: "**", with: ""))
        alert.addButton(withTitle: "Install and Reopen")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: Task { await install(release) }
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    /// Downloads the release, swaps it in for this app, and reopens it.
    func install(_ release: Release) async {
        guard !installing else { return }
        guard !isBusy() else { info("Finish the current task first", "The update is ready. Install it once Clinqy has finished its running tasks."); return }
        installing = true
        defer { installing = false }
        let target = Bundle.main.bundleURL
        var stagedApp: URL?
        var handedOff = false
        defer { if !handedOff, let stagedApp { try? FileManager.default.removeItem(at: stagedApp.deletingLastPathComponent()) } }
        do {
            let staged = try await Self.download(release)
            stagedApp = staged
            guard !isBusy(), !Task.isCancelled else { throw NSError(domain: "Clinqy", code: 6, userInfo: [NSLocalizedDescriptionKey: "A task started while the update downloaded. Finish it, then install the update again."]) }
            guard target.path.hasSuffix(".app") else { throw NSError(domain: "Clinqy", code: 2, userInfo: [NSLocalizedDescriptionKey: "Clinqy isn't running from an app bundle"]) }
            try Self.swapInAndReopen(staged, replacing: target, waitingFor: getpid())
            handedOff = true
            Agent.writeLog("update: installing \(release.version), reopening")
            NSApp.terminate(nil)
        } catch {
            info("Couldn't install the update", error.localizedDescription + "\n\nYou can download it from the release page instead.")
            NSWorkspace.shared.open(release.page)
        }
    }

    /// Downloads the disk image and copies the app out of it into a staging folder; returns the staged app.
    nonisolated static func download(_ release: Release) async throws -> URL {
        var request = URLRequest(url: release.dmg)
        request.timeoutInterval = 120
        let (file, response) = try await URLSession.shared.download(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Clinqy", code: 3, userInfo: [NSLocalizedDescriptionKey: "the download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"])
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-update-\(release.version)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var keepStagedApp = false
        defer { if !keepStagedApp { try? FileManager.default.removeItem(at: work) } }
        let dmg = work.appendingPathComponent("Clinqy.dmg")
        try FileManager.default.moveItem(at: file, to: dmg)
        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        let app = mount.appendingPathComponent("Clinqy.app")
        let staged = work.appendingPathComponent("Clinqy.app")
        try run("/usr/bin/ditto", [app.path, staged.path])
        try validateApp(staged, expectedVersion: release.version)
        keepStagedApp = true
        return staged
    }

    /// The signed bundle must match the release selected before it can replace an installed copy.
    nonisolated static func validateApp(_ app: URL, expectedVersion: String) throws {
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == "com.amritnigam.clinqy" else {
            throw NSError(domain: "Clinqy", code: 4, userInfo: [NSLocalizedDescriptionKey: "the download isn't Clinqy"])
        }
        guard info?["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw NSError(domain: "Clinqy", code: 5, userInfo: [NSLocalizedDescriptionKey: "the downloaded app version does not match this release"])
        }
    }

    /// Hands the swap to a small script that waits for this process to quit, replaces the app and opens the new one.
    /// The new copy is first staged as a sibling (`<app>.new`) so the installed bundle is only touched once a complete
    /// replacement exists next to it; the original is renamed to `<app>.old` and removed only after the new one is in
    /// place. If the first rename fails the original is left exactly as it was (nothing is deleted), and a rollback only
    /// ever restores a backup that actually exists. The outcome is written to `receipt` when given
    /// (installed / unchanged / rolled-back / failed-staging).
    @discardableResult
    nonisolated static func swapInAndReopen(_ staged: URL, replacing target: URL, waitingFor pid: Int32?, reopen: Bool = true, receipt: URL? = nil) throws -> Process {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        guard staged.standardizedFileURL != target.standardizedFileURL,
              target.pathExtension == "app", staged.pathExtension == "app" else {
            throw NSError(domain: "Clinqy", code: 7, userInfo: [NSLocalizedDescriptionKey: "Update staging and destination must be separate app bundles"])
        }
        let handshake = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-update-handshake-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: handshake, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var accepted = false
        defer { if !accepted { try? FileManager.default.removeItem(at: handshake) } }
        let ready = handshake.appendingPathComponent("ready"), acknowledgment = handshake.appendingPathComponent("accepted")
        let t = q(target.path), old = q(target.path + ".old"), new = q(target.path + ".new")
        let rec = receipt.map { q($0.path) }
        let cleanup = staged.deletingLastPathComponent().lastPathComponent.hasPrefix("clinqy-update-")
            ? staged.deletingLastPathComponent() : staged
        let script = """
        report() { \(rec.map { "printf '%s\\n' \"$1\" > \($0)" } ?? ":") ; }
        cleanup() { rm -rf \(q(cleanup.path)) \(q(handshake.path)); }
        trap cleanup EXIT
        # A launched process is not proof that lockf acquired the lock. Acknowledge only inside it.
        printf ready > \(q(ready.path)) || exit 1
        attempt=0
        while [ ! -f \(q(acknowledgment.path)) ]; do
          attempt=$((attempt + 1))
          if [ "$attempt" -ge 150 ]; then report handshake-expired; exit 1; fi
          sleep 0.02
        done
        rm -rf \(q(handshake.path))
        \(pid.map { "attempt=0; while kill -0 \($0) 2>/dev/null; do attempt=$((attempt + 1)); if [ \"$attempt\" -ge 300 ]; then report waiting-for-app; exit 1; fi; sleep 0.2; done" } ?? "")
        # Keep the original intact until a complete sibling replacement exists.
        if [ -e \(old) ] && [ ! -e \(t) ]; then mv \(old) \(t) || { report failed-recovery; exit 1; }; fi
        rm -rf \(new)
        if ! /usr/bin/ditto \(q(staged.path)) \(new); then rm -rf \(new); report failed-staging; exit 1; fi
        if [ -e \(old) ]; then rm -rf \(old); fi
        if ! mv \(t) \(old); then rm -rf \(new); report unchanged; exit 1; fi
        if ! mv \(new) \(t); then
          if mv \(old) \(t); then rm -rf \(new); report rolled-back; else report failed-recovery; fi
          exit 1
        fi
        \(reopen ? """
        if ! /usr/bin/open \(t); then
          if mv \(t) \(new) && mv \(old) \(t); then
            rm -rf \(new); /usr/bin/open \(t); report rolled-back
          else report failed-recovery
          fi
          exit 1
        fi
        """ : "")
        rm -rf \(old)
        report installed
        """
        let p = Process()
        // macOS lockf(1): -k keeps one inode for all contenders; kernel ownership disappears on exit.
        // Unlike a directory lock, a crashed updater cannot leave a permanently held lock.
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let failureReceipt = rec.map { "if [ ! -e \($0) ]; then printf '%s\\n' failed-lock-or-helper > \($0); fi" } ?? ":"
        p.arguments = ["-c", "if /usr/bin/lockf -k -t 0 " + q(target.path + ".update-lock") + " /bin/sh -c " + q(script)
            + "; then exit 0; else status=$?; " + failureReceipt + "; rm -rf " + q(cleanup.path) + "; exit \"$status\"; fi"]
        try p.run()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: ready.path) {
                try Data("accepted".utf8).write(to: acknowledgment, options: .atomic)
                accepted = true
                return p
            }
            if !p.isRunning { break }
            usleep(20_000)
        }
        // No acknowledgement: even a delayed helper must exit without touching the installed bundle.
        throw NSError(domain: "Clinqy", code: 8, userInfo: [NSLocalizedDescriptionKey: "The update helper could not acquire installation ownership. Another update may be running; the current app was left open."])
    }

    @discardableResult
    nonisolated static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Clinqy", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: path).lastPathComponent) failed: \(text.prefix(200))"])
        }
        return text
    }
}
