// Isolated tests against the production Telegram bridge, with no bot credentials or running UI.
// Run: tests/telegram.sh
import AppKit

// Only the app boundary is stubbed; parsing, downloading, buffering and routing use Telegram.swift.
enum Config {
    static func value(_ key: String) -> String? { key == "TELEGRAM_BOT_TOKEN" ? "test-token" : "42" }
    static func write(_ values: [String: String]) throws {}
}
enum Secrets { static func mask(_ text: String) -> String { text } }
struct ResultCard {
    struct Item { var title: String; var subtitle: String?; var link: String? }
    var items: [Item] = []
}
@MainActor final class Agent {
    struct Question { var text: String; var sensitive = false }
    struct Step { var text: String }
    var isRunning = false
    var question: Question?
    var steps: [Step] = []
    var continuation: String?
    var selectedFiles: [URL] = []
    var submitted: [String] = []
    var notes: [String] = []
    var answers: [String] = []
    func submit(_ text: String, preferBackground: Bool) { submitted.append(text); isRunning = true }
    func addContext(_ text: String) { notes.append(text) }
    func answer(_ text: String) { answers.append(text) }
    func cancel() { isRunning = false }
    static func writeLog(_ text: String) {}
}

final class TelegramAPI: URLProtocol {
    static let lock = NSLock()
    static var requests: [(String, [String: Any])] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.url!.lastPathComponent
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var result = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count)
                if n <= 0 { break }
                result.append(contentsOf: bytes.prefix(n))
            }
            data = result
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        Self.lock.withLock { Self.requests.append((method, body)) }
        let payload: Data
        var status = 200
        if method == "getFile" {
            let id = body["file_id"] as! String
            payload = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": ["file_path": "files/\(id).jpg", "file_size": 4]])
        } else if request.url!.path.contains("/file/") {
            payload = Data("file".utf8)
            if method == "broken.jpg" { status = 500 }
        } else {
            payload = Data(#"{"ok":true,"result":true}"#.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func fileIDs() -> [String] {
        lock.withLock { requests.filter { $0.0 == "getFile" }.compactMap { $0.1["file_id"] as? String } }
    }
    static func replies() -> [String] {
        lock.withLock { requests.filter { $0.0 == "sendMessage" }.compactMap { $0.1["text"] as? String } }
    }
}

@main struct TelegramTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-telegram-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TelegramAPI.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func bridge() -> (Telegram, Agent) {
            let bot = Telegram(session: session, downloadDirectory: root)
            let agent = Agent(); bot.agent = agent
            return (bot, agent)
        }
        func message(_ extra: [String: Any], chat: Int = 42) -> [String: Any] {
            ["chat": ["id": chat, "type": "private"]].merging(extra) { _, new in new }
        }
        func document(_ id: String, _ name: String = "report.pdf", size: Int = 4) -> [String: Any] {
            ["document": ["file_id": id, "file_name": name, "file_size": size]]
        }
        func wait(_ check: () -> Bool) async throws {
            for _ in 0..<300 {
                if check() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            fatalError("Timed out waiting for Telegram")
        }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); print("PASS \(label)")
        }

        let (bot, agent) = bridge()
        bot.handle(message(["photo": [["file_id": "small", "width": 10, "height": 10],
                                      ["file_id": "large", "width": 100, "height": 100]],
                            "caption": "send this image to Onik"]))
        try await wait { agent.submitted.count == 1 }
        check(TelegramAPI.fileIDs() == ["large"], "download the largest photo only")
        check(agent.selectedFiles.count == 1 && agent.submitted[0].contains(agent.selectedFiles[0].path), "caption includes the actual local attachment")
        let contents = try Data(contentsOf: agent.selectedFiles[0])
        check(contents == Data("file".utf8), "downloaded file contents")

        let (staged, stagedAgent) = bridge()
        staged.handle(message(document("staged", "../../invoice.pdf")))
        try await wait { TelegramAPI.replies().contains { $0.contains("What should I do") } }
        check(stagedAgent.submitted.isEmpty, "file alone waits for instructions")
        staged.handle(message(["text": "read this file"]))
        try await wait { stagedAgent.submitted.count == 1 }
        check(stagedAgent.selectedFiles.first?.lastPathComponent == "invoice.pdf", "sanitize filenames and carry staged files into next instruction")

        let (album, albumAgent) = bridge()
        album.handle(message(document("album-a").merging(["media_group_id": "group", "caption": "merge these"]) { _, v in v }))
        album.handle(message(document("album-b").merging(["media_group_id": "group"]) { _, v in v }))
        try await wait { albumAgent.submitted.count == 1 }
        check(albumAgent.selectedFiles.count == 2 && albumAgent.notes.isEmpty, "album starts one task with every file")

        let (reply, replyAgent) = bridge()
        reply.handle(message(["text": "forward this", "reply_to_message": document("reply")]))
        try await wait { replyAgent.submitted.count == 1 }
        check(replyAgent.selectedFiles.count == 1, "reply downloads the referenced attachment")
        reply.handle(message(document("context").merging(["caption": "also use this"]) { _, v in v }))
        try await wait { replyAgent.notes.count == 1 }
        check(replyAgent.notes[0].contains("report.pdf"), "running task receives additional file context")

        let (bad, badAgent) = bridge()
        let requestCount = TelegramAPI.fileIDs().count
        bad.handle(message(document("oversized", size: 21 * 1024 * 1024).merging(["caption": "send this"]) { _, v in v }))
        try await wait { TelegramAPI.replies().contains { $0.contains("exceeds Telegram") } }
        check(badAgent.submitted.isEmpty && TelegramAPI.fileIDs().count == requestCount, "oversized files fail before a task or download starts")
        bad.handle(message(document("broken").merging(["caption": "send this"]) { _, v in v }))
        try await wait { TelegramAPI.replies().contains { $0.contains("file download failed") } }
        check(badAgent.submitted.isEmpty, "failed downloads do not execute the caption")
        bad.handle(message(document("stranger").merging(["caption": "do this"]) { _, v in v }, chat: 99))
        try await Task.sleep(for: .milliseconds(50))
        check(!TelegramAPI.fileIDs().contains("stranger"), "unpaired chats cannot download files or run tasks")

        let (queued, busyAgent) = bridge()
        busyAgent.isRunning = true
        queued.handle(message(document("queued").merging(["caption": "process this later"]) { _, v in v }))
        try await wait { TelegramAPI.replies().contains { $0.contains("start this with its files") } }
        busyAgent.isRunning = false
        queued.finished(answer: "Done", ok: true, result: nil)
        try await wait { busyAgent.submitted.count == 1 }
        check(busyAgent.selectedFiles.count == 1, "queued tasks retain attachments")

        let (stopped, stoppedAgent) = bridge()
        stopped.handle(message(document("stop-album").merging(["caption": "send this", "media_group_id": "stop"]) { _, v in v }))
        stopped.handle(message(["text": "/stop"]))
        try await Task.sleep(for: .milliseconds(1000))
        check(stoppedAgent.submitted.isEmpty && !TelegramAPI.fileIDs().contains("stop-album"), "stop cancels pending album ingestion")
        print("All Telegram attachment tests passed.")
    }
}
