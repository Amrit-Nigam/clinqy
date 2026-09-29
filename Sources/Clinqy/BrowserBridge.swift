import AppKit
import Network

/// Talks to the Clinqy browser extension over a localhost WebSocket. The extension reads the live page
/// (exact buttons, links, fields and where they are) and performs precise clicks and fills in it.
/// Only browser-extension origins may connect, so web pages can't reach this server.
@MainActor
final class BrowserBridge {
    static let shared = BrowserBridge()
    static let port: NWEndpoint.Port = 47823

    struct PageElement {
        let index: Int
        let role: String
        let text: String
        /// Rect in page viewport coordinates.
        let rect: CGRect
        let editable: Bool
        let extra: String
    }

    struct Page {
        let connection: ObjectIdentifier
        let url: String
        let title: String
        let viewport: CGSize
        let scrollY: Double
        let scrollMax: Double
        let headings: [String]
        let elements: [PageElement]
        /// Error/status messages showing on the page ("This is a required question").
        var messages: [String] = []
        /// Visible text that isn't an element (confirmations, details, prices).
        var text = ""
        /// Fields/buttons above and below the visible part (so the model knows to scroll).
        var above = 0, below = 0
        /// document.readyState ("loading" = still arriving).
        var ready = "complete"
        /// Why the page couldn't be read, when it couldn't (never just "0 elements").
        var problem: String?
        /// Viewport's on-screen rect estimated from window geometry (fallback when Accessibility can't say).
        let estimatedArea: CGRect?
    }

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var counter = 0

    var isConnected: Bool { !connections.isEmpty }

    enum BridgeError: LocalizedError {
        case notConnected, timeout, failed(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "browser extension not connected"
            case .timeout: return "browser extension didn't answer"
            case .failed(let why): return why
            }
        }
    }

    func start() {
        guard listener == nil else { return }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // Browser pages send their own origin; only extensions (chrome-extension://…) are let in.
        ws.setClientRequestHandler(.main) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? ""
            let ok = origin.hasPrefix("chrome-extension://") || origin.hasPrefix("moz-extension://")
            return .init(status: ok ? .accept : .reject, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Self.port)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated { self?.accept(conn) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    self?.connections[key] = conn
                    self?.identify(conn, key: key)
                case .failed, .cancelled:
                    self?.connections[key] = nil
                    self?.owners[key] = nil
                default: break
                }
            }
        }
        conn.start(queue: .main)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any], msg["type"] as? String == "hello" {
                    self.checkVersion(msg["version"] as? String ?? "", on: conn)
                }
                if let data, let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = msg["id"] as? String, let cont = self.pending.removeValue(forKey: id) {
                    if msg["ok"] as? Bool == true {
                        cont.resume(returning: (msg["result"] as? [String: Any]) ?? [:])
                    } else {
                        cont.resume(throwing: BridgeError.failed(msg["error"] as? String ?? "extension error"))
                    }
                }
                if error == nil { self.receive(conn) } else { self.connections[ObjectIdentifier(conn)] = nil }
            }
        }
    }

    private func request(_ conn: NWConnection, _ body: [String: Any], timeout: Double = 2.5) async throws -> [String: Any] {
        counter += 1
        let id = "r\(counter)"
        var msg = body
        msg["id"] = id
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { throw BridgeError.failed("bad request") }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            conn.send(content: data, contentContext: .init(identifier: "msg", metadata: [meta]), isComplete: true,
                      completion: .contentProcessed { _ in })
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.pending.removeValue(forKey: id)?.resume(throwing: BridgeError.timeout)
            }
        }
    }

    /// The extension version this app was built with (extension/manifest.json). A browser still running an older
    /// copy is told to reload it from disk, once per version, so updates never need a manual reload.
    static let extensionVersion = "1.5.1"
    private var reloadAsked: Set<String> = []

    private func checkVersion(_ version: String, on conn: NWConnection) {
        guard version != Self.extensionVersion, !reloadAsked.contains(version) else { return }
        reloadAsked.insert(version)
        Agent.writeLog("browser extension v\(version) connected, app expects v\(Self.extensionVersion): reloading it")
        Task { _ = try? await request(conn, ["cmd": "reload"], timeout: 5) }
    }

    /// Asks every connected browser to reload the extension (after it's been updated on disk).
    func reloadAll() async -> Int {
        var n = 0
        for (_, conn) in connections where (try? await request(conn, ["cmd": "reload"], timeout: 5)) != nil { n += 1 }
        return n
    }

    /// Debug: every connected browser's raw answer to a snapshot request.
    func debugSnapshots() async -> [String] {
        var out: [String] = []
        for (_, conn) in connections {
            do {
                let v = (try? await request(conn, ["cmd": "version"], timeout: 3))?["version"] as? String ?? "?"
                let r = try await request(conn, ["cmd": "snapshot"], timeout: 5)
                out.append("v\(v) screen=\(r["screen"] != nil) focused=\(r["focused"] ?? "nil") url=\(r["url"] ?? "-") elements=\((r["elements"] as? [Any])?.count ?? -1) restricted=\(r["restricted"] ?? false)")
            } catch { out.append("error: \(error.localizedDescription)") }
        }
        return out
    }

    /// Text selected on the page in the focused browser window, if any.
    func selection(in app: NSRunningApplication? = nil) async -> String? {
        for (_, conn) in candidates(for: app) {
            guard let r = try? await request(conn, ["cmd": "selection"], timeout: 1.2), r["focused"] as? Bool == true else { continue }
            let text = (r["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    struct TabInfo { let id: Int; let url: String; let connection: ObjectIdentifier }

    /// The active tab of the focused browser window.
    func activeTab(in app: NSRunningApplication? = nil) async -> TabInfo? {
        for (key, conn) in candidates(for: app) {
            guard let r = try? await request(conn, ["cmd": "tabInfo"], timeout: 1.5), r["focused"] as? Bool == true,
                  let id = r["id"] as? Int else { continue }
            return TabInfo(id: id, url: r["url"] as? String ?? "", connection: key)
        }
        return nil
    }

    /// Runs a tab-level command (newTab, goBack, navigate) in the browser that owns `tab`.
    @discardableResult
    func tabCommand(_ cmd: String, on tab: TabInfo, _ args: [String: Any] = [:]) async -> [String: Any]? {
        guard let conn = connections[tab.connection] else { return nil }
        var body = args
        body["cmd"] = cmd
        return try? await request(conn, body, timeout: 3)
    }

    // MARK: - Page API

    /// Snapshot of the page in the focused browser window (asks every connected browser; the focused one answers for itself).
    /// Which browser each connection comes from (its app bundle path, e.g. /Applications/Arc.app), found from
    /// the process on the other end. A page must only ever be read from the browser that's actually in front:
    /// with Chrome in front and only Arc connected, Arc's tab must not be mistaken for Chrome's.
    private var owners: [ObjectIdentifier: String] = [:]

    private func identify(_ conn: NWConnection, key: ObjectIdentifier) {
        guard case let .hostPort(_, port) = conn.endpoint else { return }
        Task.detached {
            let r = await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port.rawValue)", "-sTCP:ESTABLISHED", "-Fp"], timeout: 5)
            let me = ProcessInfo.processInfo.processIdentifier
            let pids = r.output.split(separator: "\n").filter { $0.hasPrefix("p") }.compactMap { Int32($0.dropFirst()) }.filter { $0 != me }
            var bundle: String?
            for pid in pids {
                var buf = [CChar](repeating: 0, count: 4096)
                guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
                let path = String(cString: buf)
                if let r = path.range(of: ".app/") { bundle = String(path[..<r.lowerBound]) + ".app"; break }
            }
            let owner = bundle
            await MainActor.run { self.owners[key] = owner ?? "?" }
        }
    }

    /// Connections to ask about `app` (a browser): its own; while a connection is still being identified, that
    /// one too; none if this browser has no extension connected. nil app = any (the focused window decides).
    private func candidates(for app: NSRunningApplication?) -> [(ObjectIdentifier, NWConnection)] {
        let all = connections.map { ($0.key, $0.value) }
        guard let bundle = app?.bundleURL?.resolvingSymlinksInPath().path else { return all }
        let own = all.filter { owners[$0.0] == bundle }
        return own.isEmpty ? all.filter { owners[$0.0] == nil } : own
    }

    func snapshot(for app: NSRunningApplication? = nil) async -> Page? {
        let pool = candidates(for: app)
        for (key, conn) in pool {
            guard let r = try? await request(conn, ["cmd": "snapshot"], timeout: 5), r["focused"] as? Bool == true else { continue }
            return parse(r, connection: key)
        }
        // Nobody reports focus (e.g. the page hasn't got keyboard focus yet): use the only candidate, if one.
        if pool.count == 1, let (key, conn) = pool.first,
           let r = try? await request(conn, ["cmd": "snapshot"], timeout: 5) {
            return parse(r, connection: key)
        }
        return nil
    }

    func perform(_ cmd: String, on page: Page, _ args: [String: Any] = [:], timeout: Double = 4) async throws -> [String: Any] {
        guard let conn = connections[page.connection] else { throw BridgeError.notConnected }
        var body = args
        body["cmd"] = cmd
        return try await request(conn, body, timeout: timeout)
    }

    /// The viewport sits at the bottom of the window, flush with its sides: window origin + the difference
    /// between outer and inner size (toolbars on top, side panels split evenly).
    private static func estimate(_ r: [String: Any]) -> CGRect? {
        guard let sc = r["screen"] as? [String: Any], let vp = r["viewport"] as? [String: Any] else { return nil }
        func d(_ o: [String: Any], _ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        guard let x = d(sc, "x"), let y = d(sc, "y"), let ow = d(sc, "ow"), let oh = d(sc, "oh"),
              let vw = d(vp, "w"), let vh = d(vp, "h"), vw > 0, vh > 0 else { return nil }
        return CGRect(x: x + max(0, ow - vw) / 2, y: y + max(0, oh - vh), width: vw, height: vh)
    }

    private func parse(_ r: [String: Any], connection: ObjectIdentifier) -> Page {
        let vp = r["viewport"] as? [String: Any]
        let scroll = r["scroll"] as? [String: Any]
        let els = (r["elements"] as? [[String: Any]] ?? []).map { e -> PageElement in
            func d(_ k: String) -> Double { (e[k] as? NSNumber)?.doubleValue ?? 0 }
            var extra: [String] = []
            if let q = e["q"] as? String { extra.append("in “\(q)”") }
            if let frame = e["frame"] as? String { extra.append("inside \(frame)") }
            if e["dropdown"] as? Bool == true { extra.append("dropdown") }
            if let v = e["value"] as? String { extra.append("value=\(v.debugDescription)") }
            if let p = e["placeholder"] as? String, (e["text"] as? String) != p { extra.append("placeholder=\(p.debugDescription)") }
            if let o = e["options"] as? String { extra.append("options: \(o)") }
            for flag in ["required", "invalid", "focused", "checked", "unchecked", "selected", "disabled", "covered"] where e[flag] as? Bool == true { extra.append(flag) }
            if let href = e["href"] as? String { extra.append("→ \(href)") }
            return PageElement(index: (e["i"] as? Int) ?? 0, role: e["role"] as? String ?? "?", text: e["text"] as? String ?? "",
                               rect: CGRect(x: d("x"), y: d("y"), width: d("w"), height: d("h")),
                               editable: e["editable"] as? Bool == true, extra: extra.joined(separator: " "))
        }
        return Page(connection: connection, url: r["url"] as? String ?? "", title: r["title"] as? String ?? "",
                    viewport: CGSize(width: (vp?["w"] as? NSNumber)?.doubleValue ?? 1, height: (vp?["h"] as? NSNumber)?.doubleValue ?? 1),
                    scrollY: (scroll?["y"] as? NSNumber)?.doubleValue ?? 0, scrollMax: (scroll?["max"] as? NSNumber)?.doubleValue ?? 0,
                    headings: r["headings"] as? [String] ?? [], elements: els,
                    messages: r["messages"] as? [String] ?? [], text: r["text"] as? String ?? "",
                    above: r["above"] as? Int ?? 0, below: r["below"] as? Int ?? 0, ready: r["ready"] as? String ?? "complete",
                    problem: r["error"] as? String, estimatedArea: Self.estimate(r))
    }
}
