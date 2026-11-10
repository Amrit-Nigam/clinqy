import Foundation
import Darwin

/// Local transport between `Clinqy mcp` (client) and the running app (server): a Unix domain socket carrying
/// length-prefixed JSON. It replaces the request-file + `open clinqy://control` + 100 ms polling relay; the MCP
/// side falls back to that relay when the socket is unavailable.
///
/// Frame: 4-byte big-endian length, then that many bytes of a JSON object.
/// Request:  the control body (plus `deadline`), or `{"cancel": "<session>"}`.
/// Response: the tool result object (`{"content": [...], "isError": ...}`).
enum ControlSocket {
    static let maxFrame = 32 * 1024 * 1024

    static var path: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clinqy/control.sock").path
    }

    // MARK: Framing (pure)

    static func frame(_ object: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              body.count <= maxFrame else { return nil }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Length announced by a 4-byte header, or nil when it is empty or over the limit.
    static func length(of header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let n = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return n > 0 && Int(n) <= maxFrame ? Int(n) : nil
    }

    static func decode(_ body: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    // MARK: Low-level IO

    private static func address(_ path: String) -> (sockaddr_un, socklen_t)? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    private static func connectOrBind(_ fd: Int32, _ path: String, bind isBind: Bool) -> Bool {
        guard let (a, len) = address(path) else { return false }
        var addr = a
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { isBind ? Darwin.bind(fd, $0, len) == 0 : Darwin.connect(fd, $0, len) == 0 }
        }
    }

    /// Reads exactly `count` bytes; polls in 100 ms slices so `shouldStop` (task cancel) is honoured. nil on EOF/error/stop.
    private static func readExactly(_ fd: Int32, _ count: Int, shouldStop: () -> Bool = { false }, until: Date? = nil) -> Data? {
        var out = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: min(count, 65536))
        while out.count < count {
            if shouldStop() || (until.map { Date() > $0 } ?? false) { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; return nil }
            if ready == 0 { continue }
            let n = read(fd, &buffer, min(buffer.count, count - out.count))
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return nil }
            if n == 0 { return nil }
            out.append(buffer, count: n)
        }
        return out
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            while offset < data.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
    }

    private static func readFrame(_ fd: Int32, shouldStop: () -> Bool = { false }, until: Date? = nil) -> [String: Any]? {
        guard let header = readExactly(fd, 4, shouldStop: shouldStop, until: until), let n = length(of: header),
              let body = readExactly(fd, n, shouldStop: shouldStop, until: until) else { return nil }
        return decode(body)
    }

    private static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    // MARK: Client (MCP process)

    enum ClientResult {
        case response([String: Any])
        /// Nothing was delivered; the caller may use the file relay.
        case unavailable
        /// The request may have been delivered but no answer arrived. Never replay a mutation.
        case noAnswer
    }

    /// One request, one response, on a fresh connection. Blocking; call from a detached task.
    static func request(_ body: [String: Any], timeout: TimeInterval, path: String = ControlSocket.path,
                        shouldStop: () -> Bool = { false }) -> ClientResult {
        guard let payload = frame(body) else { return .unavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard connectOrBind(fd, path, bind: false), peerIsCurrentUser(fd) else { return .unavailable }
        guard writeAll(fd, payload) else { return .noAnswer }
        guard let reply = readFrame(fd, shouldStop: shouldStop, until: Date().addingTimeInterval(timeout)) else { return .noAnswer }
        return .response(reply)
    }

    // MARK: Server (app)

    nonisolated(unsafe) private static var listener: Int32 = -1
    /// Bumped on every serve/stop, so an old accept thread recognises it is stale even if its descriptor number was reused.
    nonisolated(unsafe) private static var generation = 0
    private static let lock = NSLock()

    /// Whether `fd` from serve generation `gen` is still the live listener.
    static func isCurrent(_ fd: Int32, generation gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return listener == fd && generation == gen
    }

    /// Starts serving; `handler` runs one control body. Returns false if the socket could not be created.
    @discardableResult
    static func serve(path: String = ControlSocket.path,
                      handler: @escaping @Sendable (UncheckedBox<[String: Any]>) async -> UncheckedBox<[String: Any]>,
                      cancel: @escaping @Sendable (String) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard listener < 0 else { return true }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let old = umask(0o177)
        let bound = connectOrBind(fd, path, bind: true)
        umask(old)
        guard bound, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else { close(fd); unlink(path); return false }
        listener = fd
        generation += 1
        let gen = generation
        Thread.detachNewThread {
            while isCurrent(fd, generation: gen) {
                let client = accept(fd, nil, nil)
                // Stopped (or the descriptor now belongs to someone else): never serve on it.
                guard isCurrent(fd, generation: gen) else { if client >= 0 { close(client) }; return }
                if client < 0 { if errno == EINTR { continue }; return }
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                guard peerIsCurrentUser(client) else { close(client); continue }
                Thread.detachNewThread { handle(client, handler: handler, cancel: cancel) }
            }
        }
        return true
    }

    static func stop(path: String = ControlSocket.path) {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        // close() alone doesn't reliably wake a thread blocked in accept() on Darwin; shutdown does.
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
        unlink(path)
    }

    private static func handle(_ fd: Int32, handler: @escaping @Sendable (UncheckedBox<[String: Any]>) async -> UncheckedBox<[String: Any]>,
                               cancel: @Sendable (String) -> Void) {
        defer { close(fd) }
        guard let body = readFrame(fd, until: Date().addingTimeInterval(10)) else { return }
        if let session = body["cancel"] as? String { cancel(session); _ = frame([:]).map { writeAll(fd, $0) }; return }
        // Same rules as the file relay: an expired deadline is never executed.
        guard let deadline = body["deadline"] as? Double, deadline >= Date().timeIntervalSince1970 else { return }
        let box = UncheckedBox(body)
        let done = DispatchSemaphore(value: 0)
        let result = ResultSlot()
        Task.detached { result.set(await handler(box).value); done.signal() }
        // Wake periodically so a vanished client does not leave this thread blocked forever.
        while done.wait(timeout: .now() + 1) == .timedOut {}
        if let reply = frame(result.get()) { _ = writeAll(fd, reply) }
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private final class ResultSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: Any] = [:]
    func set(_ v: [String: Any]) { lock.withLock { value = v } }
    func get() -> [String: Any] { lock.withLock { value } }
}
