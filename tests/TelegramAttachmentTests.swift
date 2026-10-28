// Isolated tests against the production Telegram bridge, with no bot credentials or running UI.
// Run: tests/telegram.sh
import AppKit

// Only the app boundary is stubbed; parsing, downloading, buffering and routing use Telegram.swift.
enum Config {
    static func value(_ key: String) -> String? { key == "TELEGRAM_BOT_TOKEN" ? "test-token" : "42" }
    static func write(_ values: [String: String]) throws {}
}
enum Secrets { static func mask(_ text: String) -> String { text } }
struct ResultCard: Equatable {
    struct Item: Equatable { var title: String; var subtitle: String?; var detail: String? = nil; var link: String? }
    var title = "Result"
    var text: String? = nil
    var items: [Item] = []
    var plain: String { ([title] + [text].compactMap { $0 } + items.map { [$0.title, $0.subtitle, $0.detail, $0.link].compactMap { $0 }.joined(separator: " — ") }).joined(separator: "\n") }
}
enum Background {
    static func choice(_ text: inout String) -> Bool? { nil }
}
@MainActor final class Agent {
    struct Question { var text: String; var sensitive = false }
    struct Step {
        enum State { case running, ok, failed, info }
        var text: String
        var state: State = .ok
    }
    var store: TaskStore?
    var isRunning = false {
        didSet { if oldValue && !isRunning, let id = store?.active?.id { store?.finish(id, ok: true, answer: "Finished") } }
    }
    var question: Question?
    var steps: [Step] = []
    var narration = ""
    var telegramPageURL: String? = nil
    var screenshot: Data? = nil
    var captures = 0
    var continuation: String?
    var selectedFiles: [URL] = []
    var submitted: [String] = []
    var notes: [String] = []
    var answers: [String] = []
    func submit(_ text: String, background: Bool, taskID: UUID? = nil) { submitted.append(text); isRunning = true }
    func addContext(_ text: String) { notes.append(text) }
    func answer(_ text: String) { answers.append(text); question = nil }
    func cancel() { isRunning = false }
    func telegramScreenshot() async -> Data? { captures += 1; return screenshot }
    static func writeLog(_ text: String) {}
}

final class TelegramAPI: URLProtocol {
    static let lock = NSLock()
    static var requests: [(String, [String: Any])] = []
    static var rawRequests: [(String, Data)] = []
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
        Self.lock.withLock {
            Self.requests.append((method, body))
            Self.rawRequests.append((method, data ?? Data()))
        }
        let payload: Data
        var status = 200
        if method == "getFile" {
            let id = body["file_id"] as! String
            payload = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": ["file_path": "files/\(id).jpg", "file_size": 4]])
        } else if request.url!.path.contains("/file/") {
            payload = Data("file".utf8)
            if method == "broken.jpg" { status = 500 }
        } else {
            payload = Data(#"{"ok":true,"result":{"message_id":123}}"#.utf8)
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
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-telegram-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TelegramAPI.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func bridge() -> (Telegram, Agent) {
            let store = TaskStore(file: root.appendingPathComponent(UUID().uuidString + ".json"))
            let bot = Telegram(session: session, downloadDirectory: root, store: store)
            let agent = Agent(); agent.store = store; bot.agent = agent
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
        // Conversational commands remain separate from the worker's answers/context.
        check(Telegram.formKey(url: "test/form", answers: [("City", "Delhi")]) != Telegram.formKey(url: "test/form", answers: [("City", "Pune")]), "form changes invalidate an earlier submission approval")
        check(Telegram.formKey(url: "test/form", answers: [("City", "Delhi")]) != Telegram.formKey(url: "test/other-form", answers: [("City", "Delhi")]), "submission approval cannot transfer to another form")
        check(Telegram.intent("Can you send me an image of what you're doing right now?") == .screenshot, "conversational screenshot phrasing")
        check(Telegram.intent("How much work is done?") == .status, "natural-language progress intent")
        check(Telegram.intent("show me a screenshot") == .screenshot, "natural-language screenshot intent")
        check(Telegram.intent("set the status to available") == nil, "task text is not mistaken for a command")
        check(Telegram.intent("what did you fill?") == .result, "natural-language form review intent")
        let (conversation, worker) = bridge()
        conversation.handle(message(["text": "fill the sample form"]))
        try await wait { worker.submitted.count == 1 }
        worker.steps = [.init(text: "Opened form"), .init(text: "Filled name"), .init(text: "Waiting", state: .running)]
        worker.narration = "Filling the contact details"
        worker.question = .init(text: "Which location?")
        worker.store?.update(worker.store?.active?.id, state: .waiting, stage: "Which location?", completedSteps: 2)
        conversation.ask("Which location?", options: ["Delhi", "Mumbai"], sensitive: false)
        try await wait { TelegramAPI.replies().contains { $0.contains("I need your input: Which location?") } }
        conversation.handle(message(["text": "how far along?"]))
        try await wait { TelegramAPI.replies().contains { $0.contains("Now: Which location?") && $0.contains("2 steps completed") } }
        check(worker.answers.isEmpty && worker.notes.isEmpty, "progress does not answer or steer the pending question")
        check(TelegramAPI.replies().contains { $0.contains(worker.store!.active!.status) }, "Telegram and Mac task store report identical task state")
        let prior = worker.answers.count
        conversation.handle(message(["text":"/tasks"]))
        try await wait { TelegramAPI.replies().contains { $0.contains("/run <id>") } }
        check(worker.answers.count == prior, "recovery commands do not answer a pending question")

        let option = TelegramAPI.lock.withLock {
            TelegramAPI.requests.reversed().compactMap { _, body -> String? in
                guard let markup = body["reply_markup"] as? [String: Any], let rows = markup["inline_keyboard"] as? [[[String: String]]] else { return nil }
                return rows.flatMap { $0 }.first { $0["text"] == "Delhi" }?["callback_data"]
            }.first!
        }
        func tap(_ data: String, chat: Int = 42) -> [String: Any] {
            ["id": UUID().uuidString, "message": message(["message_id": 123], chat: chat), "data": data]
        }
        conversation.handleTap(tap(option))
        check(worker.answers == ["Delhi"], "current question option answers the worker")
        worker.question = .init(text: "Which role?")
        conversation.ask("Which role?", options: ["Engineer"], sensitive: false)
        conversation.handleTap(tap(option))
        check(worker.answers == ["Delhi"], "old question button cannot answer the next question")
        conversation.handleTap(tap(option, chat: 99))
        check(worker.answers == ["Delhi"], "unpaired callback cannot answer questions")

        // Screenshot commands upload only the worker's supplied image, without consuming the answer.
        worker.screenshot = Data("test-image".utf8)
        conversation.handle(message(["text": "/screenshot"]))
        try await wait { TelegramAPI.lock.withLock { TelegramAPI.rawRequests.contains { $0.0 == "sendPhoto" } } }
        check(worker.captures == 1 && worker.answers.count == 1, "screenshot request does not consume a pending answer")
        let photoBody = TelegramAPI.lock.withLock { TelegramAPI.rawRequests.first { $0.0 == "sendPhoto" }!.1 }
        check(String(data: photoBody, encoding: .utf8)?.contains("test-image") == true, "screenshot delivered as multipart photo upload")
        worker.question = .init(text: "Secret internal password prompt", sensitive: true)
        conversation.ask(worker.question!.text, options: ["secret"], sensitive: true)
        conversation.handle(message(["text": "/screenshot"]))
        conversation.handle(message(["text": "/status"]))
        try await wait { TelegramAPI.replies().contains { $0.contains("screenshots are paused") } }
        check(worker.captures == 1, "screenshots blocked while waiting for private input")
        check(!TelegramAPI.replies().contains { $0.contains("Secret internal password prompt") }, "sensitive question text stays off Telegram")
        conversation.handle(message(["text": "secret answer"]))
        try await wait { TelegramAPI.replies().contains { $0.contains("That one's private") } }
        check(worker.answers == ["Delhi"], "private answers cannot arrive through Telegram")
        worker.question = nil

        let largeReview = ResultCard(title: "Form review", text: "All required fields filled", items: (0..<25).map {
            .init(title: "Field \($0)", subtitle: String(repeating: "value ", count: 60), detail: "detail \($0)", link: nil)
        })
        conversation.present(largeReview)
        try await wait { TelegramAPI.replies().contains { $0.contains("Field 24") } }
        check(TelegramAPI.replies().contains { $0.contains("detail 24") }, "full review includes every field and detail across message chunks")
        let unicode = String(repeating: "👩🏽‍💻", count: 1000)
        let chunks = Telegram.chunks(unicode)
        check(chunks.joined() == unicode && chunks.allSatisfy { $0.utf16.count <= 3800 }, "long messages split within Telegram limits without losing Unicode")
        worker.isRunning = false
        conversation.finished(answer: "Filled, not submitted", ok: true, result: largeReview)
        try await wait { TelegramAPI.lock.withLock { TelegramAPI.rawRequests.filter { $0.0 == "sendPhoto" }.count >= 2 } }
        conversation.handle(message(["text": "/screenshot"]))
        try await wait { TelegramAPI.lock.withLock { TelegramAPI.rawRequests.filter { $0.0 == "sendPhoto" }.count >= 3 } }
        check(worker.captures == 2, "completed screenshot is saved and reused without recapturing another window")
        let resultStart = TelegramAPI.replies().count
        conversation.handle(message(["text": "/result"]))
        try await wait { TelegramAPI.replies().dropFirst(resultStart).contains { $0.contains("Filled, not submitted") } }
        check(TelegramAPI.replies().dropFirst(resultStart).contains { $0.contains("Filled, not submitted") }, "result command includes the completion status alongside form fields")
        conversation.handle(message(["text": "change the location to Pune"]))
        try await wait { worker.submitted.count == 2 }
        check(worker.submitted.last!.contains("Previous Telegram task") && worker.submitted.last!.contains("Filled, not submitted"), "follow-ups retain the previous task and result")
        conversation.handleTap(tap(option))
        check(worker.answers.count == 1, "old question buttons remain invalid after a new task")
        conversation.handle(message(["text": "/stop"]))
        print("All Telegram attachment and conversation tests passed.")
    }
}
