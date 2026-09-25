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
                case .ready: self?.connections[key] = conn
                case .failed, .cancelled: self?.connections[key] = nil
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
    func selection() async -> String? {
        for (_, conn) in connections {
            guard let r = try? await request(conn, ["cmd": "selection"], timeout: 1.2), r["focused"] as? Bool == true else { continue }
            let text = (r["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    struct TabInfo { let id: Int; let url: String; let connection: ObjectIdentifier }

    /// The active tab of the focused browser window.
    func activeTab() async -> TabInfo? {
        for (key, conn) in connections {
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
    func snapshot() async -> Page? {
        for (key, conn) in connections {
            guard let r = try? await request(conn, ["cmd": "snapshot"]), r["focused"] as? Bool == true else { continue }
            return parse(r, connection: key)
        }
        // Nobody reports focus (e.g. the page hasn't got keyboard focus yet): use the only browser, if one.
        if connections.count == 1, let (key, conn) = connections.first,
           let r = try? await request(conn, ["cmd": "snapshot"]) {
            return parse(r, connection: key)
        }
        return nil
    }

    func perform(_ cmd: String, on page: Page, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        guard let conn = connections[page.connection] else { throw BridgeError.notConnected }
        var body = args
        body["cmd"] = cmd
        return try await request(conn, body, timeout: 4)
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
            if let v = e["value"] as? String { extra.append("value=\(v.debugDescription)") }
            if let p = e["placeholder"] as? String, (e["text"] as? String) != p { extra.append("placeholder=\(p.debugDescription)") }
            if let o = e["options"] as? String { extra.append("options: \(o)") }
            for flag in ["focused", "checked", "selected", "disabled", "covered"] where e[flag] as? Bool == true { extra.append(flag) }
            if let href = e["href"] as? String { extra.append("→ \(href)") }
            return PageElement(index: (e["i"] as? Int) ?? 0, role: e["role"] as? String ?? "?", text: e["text"] as? String ?? "",
                               rect: CGRect(x: d("x"), y: d("y"), width: d("w"), height: d("h")),
                               editable: e["editable"] as? Bool == true, extra: extra.joined(separator: " "))
        }
        return Page(connection: connection, url: r["url"] as? String ?? "", title: r["title"] as? String ?? "",
                    viewport: CGSize(width: (vp?["w"] as? NSNumber)?.doubleValue ?? 1, height: (vp?["h"] as? NSNumber)?.doubleValue ?? 1),
                    scrollY: (scroll?["y"] as? NSNumber)?.doubleValue ?? 0, scrollMax: (scroll?["max"] as? NSNumber)?.doubleValue ?? 0,
                    headings: r["headings"] as? [String] ?? [], elements: els,
                    estimatedArea: Self.estimate(r))
    }
}
