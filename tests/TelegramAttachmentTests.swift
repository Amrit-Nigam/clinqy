// Production Telegram routing and transport, with app execution and the Bot API isolated.
import AppKit

enum Config {
    static var overrides: [String: String] = [:]
    static func value(_ key: String) -> String? { key == "TELEGRAM_BOT_TOKEN" ? "test-token" : key == "TELEGRAM_CHAT_ID" ? "42" : overrides[key] }
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
enum Background { static func choice(_ text: inout String) -> Bool? { ExecutionMode.choice(&text) } }
struct Workflow { var name: String }
@MainActor final class Workflows { static let shared = Workflows(); var all: [Workflow] = [] }
@MainActor final class Agent {
    struct Question { var text: String; var sensitive = false }
    struct Step { enum State { case running, ok, failed, info }; var text: String; var state: State = .ok }
    var store: TaskStore!
    var taskRecordID: UUID?
    var imageOutputRequirement: Int?
    var outputFiles: [URL] = []
    var isRunning = false
    var question: Question?
    var steps: [Step] = []
    var narration = ""
    var answer = ""
    var telegramPageURL: String?
    var screenshot: Data?
    var captures = 0
    var reveals = 0
    var continuation: String?
    var targetApp: NSRunningApplication?
    var selectedText: String?
    var copied: String?
    var annotation: String?
    var selectedFiles: [URL] = []
    var submitted: [String] = []
    var modes: [Bool] = []
    var notes: [String] = []
    var answers: [String] = []
    var onFinish: ((String, Bool) -> Void)?
    func submit(_ text: String, background: Bool, taskID: UUID? = nil) {
        taskRecordID = taskID; submitted.append(text); modes.append(background); isRunning = true
    }
    func addContext(_ text: String) { notes.append(text) }
    func answer(_ text: String) { answers.append(text); question = nil }
    func complete(_ text: String = "Finished", ok: Bool = true) {
        answer = text; isRunning = false; store.finish(taskRecordID, ok: ok, answer: text); onFinish?(text, ok)
    }
    func cancel() { complete("Stopped", ok: false) }
    func telegramScreenshot() async -> Data? { captures += 1; return screenshot }
    /// The view captured as the run finished (before its task tab was released); nil = none taken.
    var finalShot: Data?
    var finalReads = 0
    var hangFinal = false
    func finalScreenshot(for taskID: UUID?) async -> Data? { finalReads += 1; if hangFinal { try? await Task.sleep(nanoseconds: 60_000_000_000) }; return taskID == taskRecordID ? finalShot : nil }
    func revealTelegramTarget() async { reveals += 1 }
    static func writeLog(_ text: String) {}
}
final class TelegramAPI: URLProtocol {
    static let lock = NSLock()
    static var requests: [(String, [String: Any])] = []
    static var rawRequests: [(String, Data)] = []
    static var nextMessage = 100
    static var failPhotos = false
    static var rateLimited = 0
    static var limitedHits = 0
    /// Text fields of a multipart upload; JSON fields (reply_markup, media) decoded; files recorded as "_file_<name>".
    static func multipart(_ data: Data, boundary: String) -> [String: Any] {
        var fields: [String: Any] = [:]
        let separator = Data(("--" + boundary).utf8)
        var parts: [Data] = [], rest = data[...]
        while let range = rest.range(of: separator) {
            let part = rest[..<range.lowerBound]; if !part.isEmpty { parts.append(Data(part)) }
            rest = rest[range.upperBound...]
        }
        for part in parts {
            guard let split = part.range(of: Data("\r\n\r\n".utf8)), let header = String(data: part[..<split.lowerBound], encoding: .utf8),
                  let name = header.firstMatch(of: /name="([^"]+)"/)?.1 else { continue }
            var value = part[split.upperBound...]
            if value.suffix(2) == Data("\r\n".utf8) { value = value.dropLast(2) }
            if header.contains("filename=") { fields["_file_" + name] = Data(value); continue }
            let text = String(data: Data(value), encoding: .utf8) ?? ""
            if ["reply_markup", "media"].contains(String(name)), let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { fields[String(name)] = json }
            else { fields[String(name)] = text }
        }
        return fields
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.url!.lastPathComponent
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096), result = Data()
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; result.append(contentsOf: bytes.prefix(n)) }
            data = result
        }
        var body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let type = request.value(forHTTPHeaderField: "Content-Type"), type.hasPrefix("multipart/form-data; boundary="), let data {
            body = Self.multipart(data, boundary: String(type.dropFirst("multipart/form-data; boundary=".count)))
        }
        if Self.lock.withLock({ () -> Bool in
            guard Self.rateLimited > 0, method == "sendMessage" else { return false }
            Self.rateLimited -= 1; Self.limitedHits += 1; return true
        }) {
            let payload = try! JSONSerialization.data(withJSONObject: ["ok": false, "error_code": 429, "description": "Too Many Requests: retry after 1", "parameters": ["retry_after": 1]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload); client?.urlProtocolDidFinishLoading(self); return
        }
        let id = Self.lock.withLock { () -> Int in
            Self.nextMessage += 1
            var recorded = body; recorded["_responseMessageID"] = body["message_id"] as? Int ?? Self.nextMessage
            Self.requests.append((method, recorded)); Self.rawRequests.append((method, data ?? Data()))
            return Self.nextMessage
        }
        let payload: Data; var status = 200
        if method == "getFile" {
            let file = body["file_id"] as! String
            payload = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": ["file_path": "files/\(file).jpg", "file_size": 4]])
        } else if request.url!.path.contains("/file/") {
            payload = Data("file".utf8); if method == "broken.jpg" { status = 500 }
        } else if method == "sendPhoto", Self.lock.withLock({ Self.failPhotos }) { payload = Data("{\"ok\":false}".utf8) }
        else { payload = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": ["message_id": body["message_id"] as? Int ?? id]]) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func bodies(_ method: String) -> [[String: Any]] { lock.withLock { requests.filter { $0.0 == method }.map { $0.1 } } }
    static func texts(_ method: String) -> [String] { bodies(method).compactMap { ($0["text"] ?? $0["caption"]) as? String } }
    /// Messages that appear in the chat (texts and photo captions), in order.
    static func texts() -> [String] {
        lock.withLock { requests.filter { ["sendMessage", "sendPhoto"].contains($0.0) }.compactMap { ($0.1["text"] ?? $0.1["caption"]) as? String } }
    }
    /// Every version of every live card edit.
    static func cards() -> [String] {
        lock.withLock { requests.compactMap { method, body -> String? in
            switch method {
            case "editMessageText": return body["text"] as? String
            case "editMessageCaption": return body["caption"] as? String
            case "editMessageMedia": return (body["media"] as? [String: Any])?["caption"] as? String
            default: return nil
            }
        } }
    }
    static func toasts() -> [String] { bodies("answerCallbackQuery").compactMap { $0["text"] as? String } }
    /// Newest button whose label is `title` or ends with it ("⏸ Pause", "2. No").
    static func option(_ title: String) -> String? {
        lock.withLock { requests.map(\.1) }.reversed().compactMap { body -> String? in
            guard let markup = body["reply_markup"] as? [String: Any], let rows = markup["inline_keyboard"] as? [[[String: String]]] else { return nil }
            return rows.flatMap { $0 }.first { $0["text"] == title || $0["text"]?.hasSuffix(" " + title) == true }?["callback_data"]
        }.first
    }
}
@main struct TelegramTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-telegram-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TelegramAPI.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        func bridge(captureTimeout: Double = 8) -> (Telegram, Agent, TaskStore) {
            let store = TaskStore(file: root.appendingPathComponent(UUID().uuidString + ".json"))
            let bot = Telegram(session: session, downloadDirectory: root, store: store, cardInterval: 0.05, tickInterval: 3600, captureTimeout: captureTimeout)
            let worker = Agent(); worker.store = store; bot.agent = worker
            worker.onFinish = { [weak bot, weak worker] text, ok in if let worker { bot?.finished(answer: text, ok: ok, result: nil, from: worker) } }
            return (bot, worker, store)
        }
        func message(_ text: String = "", extra: [String: Any] = [:], chat: Int = 42) -> [String: Any] {
            ["chat": ["id": chat, "type": "private"], "text": text].merging(extra) { _, new in new }
        }
        func doc(_ id: String, name: String = "report.pdf", size: Int = 4) -> [String: Any] { ["document": ["file_id": id, "file_name": name, "file_size": size]] }
        func tap(_ bot: Telegram, _ data: String, chat: Int = 42) { bot.handleTap(["id": UUID().uuidString, "message": message(extra: ["message_id": 1], chat: chat), "data": data]) }
        func wait(_ check: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline { if check() { return }; try await Task.sleep(for: .milliseconds(10)) }
            if check() { return }
            fatalError("Timed out waiting for Telegram")
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }
        func check(_ test: @autoclosure () -> Bool, _ label: String) { precondition(test(), label); print("PASS \(label)") }

        // The user's exact failure: trailing normal mode must override every global background setting.
        for text in ["Apply to this Luma use normal mode clinqy", "normal mode: open Cursor", "use normal mode open Calculator", "foreground: open Arc", "use foreground: open the browser", "use the browser in foreground mode", "open the browser in the foreground", "apply to this, not in the background"] {
            var value = text; check(ExecutionMode.choice(&value) == false, "explicit Normal routing: \(text)")
        }
        for text in ["in the background: open https://example.com", "read the file in background mode"] { var value = text; check(ExecutionMode.choice(&value) == true, "explicit Background routing") }
        for text in ["change the background color", "blur the people in the background", "type \"use normal mode\"", "calculate the normal mode of a distribution"] { var value = text; check(ExecutionMode.choice(&value) == nil, "task content is not execution mode: \(text)") }
        check(!Telegram.isBrowserJob("msg mom hi on whatsapp"), "Telegram msg on whatsapp takes the native path")
        check(!Telegram.isBrowserJob("in WhatsApp, send mom the youtube link"), "Telegram WhatsApp target is never a browser job")
        check(Telegram.isBrowserJob("in the background: open https://example.com in chrome"), "Telegram browser task is a browser job")
        // Live report C2: a negative foreground constraint must not select foreground, and the leading prefix wins.
        do {
            var value = "in the background: In TextEdit, type hello world and make it bold. Never switch to foreground mode."
            check(ExecutionMode.choice(&value) == true, "negative foreground keeps explicit background")
            check(value == "In TextEdit, type hello world and make it bold.", "constraint removed whole, request readable: \(value)")
        }
        for text in ["open Notes, never switch to foreground mode", "don't use foreground, open Notes", "open Notes without foreground", "open Notes and do not run it in the foreground"] {
            var value = text; check(ExecutionMode.choice(&value) == true, "negative foreground is not foreground: \(text)")
            check(value == "open Notes", "negative foreground removed cleanly: \(text) -> \(value)")
        }
        for text in ["in the background: open Notes and keep it in the foreground", "in the background: open Notes, not in the background"] {
            var value = text; check(ExecutionMode.choice(&value) == true, "leading background prefix wins: \(text)")
        }
        for text in ["open Notes, don't run in the background", "don't run it in the background: open Notes"] {
            var value = text; check(ExecutionMode.choice(&value) == false, "negative background still selects foreground: \(text)")
        }
        do { var value = "type \"never use foreground\" into Notes"; check(ExecutionMode.choice(&value) == nil, "quoted negative foreground is text") }

        let (mode, modeWorker, _) = bridge()
        mode.handle(message("open Calculator")); try await wait { modeWorker.submitted.count == 1 }
        check(modeWorker.modes == [true], "a Telegram task without a mode starts in the background")
        check(!TelegramAPI.texts().contains { $0.contains("Where should I run this?") }, "no mode-choice gate before Telegram tasks")
        modeWorker.complete()

        let (explicit, explicitWorker, _) = bridge()
        explicit.handle(message("Apply to https://example.com use normal mode clinqy")); try await wait { explicitWorker.submitted.count == 1 }
        check(explicitWorker.modes == [false], "normal mode in original user example starts foreground directly")
        explicitWorker.complete()

        let (photo, photoWorker, _) = bridge()
        photo.handle(message("foreground: use this image", extra: ["photo": [["file_id": "small", "width": 10, "height": 10], ["file_id": "large", "width": 100, "height": 100]]]))
        try await wait { photoWorker.submitted.count == 1 }
        check(TelegramAPI.bodies("getFile").compactMap { $0["file_id"] as? String } == ["large"], "largest photo downloaded only once")
        check(photoWorker.selectedFiles.count == 1 && photoWorker.submitted[0].contains(photoWorker.selectedFiles[0].path), "attachment exact local path reaches task")
        let photoBytes = try Data(contentsOf: photoWorker.selectedFiles[0])
        check(photoBytes == Data("file".utf8), "actual downloaded bytes preserved")
        photoWorker.complete()

        let (staged, stagedWorker, _) = bridge()
        staged.handle(message(extra: doc("staged", name: "../../invoice.pdf")))
        try await wait { TelegramAPI.texts().contains { $0.contains("What should I do") } }
        check(stagedWorker.submitted.isEmpty, "file without caption waits")
        staged.handle(message("foreground: read this file")); try await wait { stagedWorker.submitted.count == 1 }
        check(stagedWorker.selectedFiles[0].lastPathComponent == "invoice.pdf", "staged attachments retain sanitized filename")
        stagedWorker.complete()

        let (album, albumWorker, _) = bridge()
        album.handle(message("foreground: merge these", extra: doc("album-a").merging(["media_group_id": "group"]) { _, v in v }))
        album.handle(message(extra: doc("album-b").merging(["media_group_id": "group"]) { _, v in v }))
        try await wait { albumWorker.submitted.count == 1 }
        check(albumWorker.selectedFiles.count == 2, "album starts one task with every attachment")
        albumWorker.complete()

        let (bad, badWorker, _) = bridge()
        let filesBefore = TelegramAPI.bodies("getFile").count
        bad.handle(message("foreground: read this", extra: doc("oversized", size: 21 * 1024 * 1024)))
        try await wait { TelegramAPI.texts().contains { $0.contains("exceeds Telegram") } }
        check(badWorker.submitted.isEmpty && TelegramAPI.bodies("getFile").count == filesBefore, "oversized attachments never start a task")
        bad.handle(message("foreground: read this", extra: doc("broken")))
        try await wait { TelegramAPI.texts().contains { $0.contains("file download failed") } }
        check(badWorker.submitted.isEmpty, "partial attachment failures never execute captions")
        bad.handle(message("foreground: read this", extra: doc("stranger"), chat: 99)); try await settle()
        check(!TelegramAPI.bodies("getFile").contains { $0["file_id"] as? String == "stranger" }, "unpaired chats cannot access app")

        let (conversation, worker, store) = bridge()
        conversation.handle(message("foreground: fill the sample form")); try await wait { worker.submitted.count == 1 }
        worker.narration = "Filling contact details"; store.update(worker.taskRecordID, completedSteps: 2)
        worker.question = .init(text: "Which location?"); store.update(worker.taskRecordID, state: .waiting)
        conversation.ask("Which location?", options: ["Delhi", "Mumbai"], sensitive: false, from: worker)
        try await wait { TelegramAPI.option("Delhi") != nil }
        let oldQuestion = TelegramAPI.option("Delhi")!
        let oldQuestionMessage = TelegramAPI.bodies("sendMessage").last { ($0["text"] as? String)?.contains("Which location?") == true }!["_responseMessageID"] as! Int
        conversation.handle(message("how far along?")); try await wait { TelegramAPI.texts().contains { $0.contains("step 2") && $0.contains("Waiting for you") } }
        check(worker.answers.isEmpty && worker.notes.isEmpty, "status commands cannot answer a question")
        conversation.handle(message("How can I do it?")); try await wait { TelegramAPI.texts().contains { $0.contains("is still waiting") } }
        check(worker.answers.isEmpty && worker.question != nil, "help request keeps handoff paused")
        tap(conversation, TelegramAPI.option("Open on Mac")!); try await wait { worker.reveals == 1 }
        check(worker.answers.isEmpty, "Open task reveals only the task without answering")
        tap(conversation, oldQuestion); check(worker.answers == ["Delhi"], "question option answers exact worker")
        worker.question = .init(text: "Which role?")
        conversation.ask("Which role?", options: ["Engineer"], sensitive: false, from: worker)
        tap(conversation, oldQuestion); tap(conversation, oldQuestion, chat: 99)
        conversation.handle(message("Mumbai", extra: ["reply_to_message": ["message_id": oldQuestionMessage]]))
        try await wait { TelegramAPI.texts().contains { $0.contains("That question has ended") } }
        check(worker.answers == ["Delhi"], "stale and unpaired callbacks cannot answer a later question")
        worker.screenshot = Data("test-image".utf8)
        let capturesBefore = worker.captures, photosBeforeShot = TelegramAPI.bodies("sendPhoto").count
        conversation.handle(message("/screenshot")); try await wait { TelegramAPI.bodies("sendPhoto").count == photosBeforeShot + 1 }
        check(worker.captures == capturesBefore + 1 && worker.answers.count == 1, "screenshot targets requested worker and preserves pending question")
        worker.question = .init(text: "Secret internal password prompt", sensitive: true)
        conversation.ask(worker.question!.text, options: [], sensitive: true, from: worker)
        conversation.handle(message("/screenshot")); conversation.handle(message("/status")); conversation.handle(message("secret answer"))
        try await wait { TelegramAPI.texts().contains { $0.contains("screenshots are paused") } }
        check(worker.captures == capturesBefore + 1 && worker.answers.count == 1 && !TelegramAPI.texts().contains { $0.contains("Secret internal password prompt") }, "private questions block remote answers and screenshots")
        worker.question = nil
        let review = ResultCard(title: "Form review", text: "Check the actual answers", items: (0..<25).map { .init(title: "Field \($0)", subtitle: String(repeating: "value ", count: 60), detail: "detail \($0)", link: nil) })
        let beforePresent = TelegramAPI.texts().count
        conversation.present(review, from: worker); try await settle()
        check(TelegramAPI.texts().count == beforePresent, "intermediate output does not create unsolicited review spam")
        worker.question = .init(text: "Please review these answers. Submit or edit?")
        conversation.ask(worker.question!.text, options: ["Submit", "Edit"], sensitive: false, from: worker)
        try await wait { TelegramAPI.texts().contains { $0.contains("Field 24") } }
        check(TelegramAPI.texts().contains { $0.contains("detail 24") }, "submission review preserves all fields across chunks")
        let unicode = String(repeating: "👩🏽‍💻", count: 1000), chunks = Telegram.chunks(String(repeating: "👩🏽‍💻", count: 1000))
        check(chunks.joined() == unicode && chunks.allSatisfy { $0.utf16.count <= 3800 }, "message chunking preserves Unicode and Telegram limits")
        worker.question = nil
        let beforeFinish = TelegramAPI.texts().count, photosBefore = TelegramAPI.bodies("sendPhoto").count
        worker.complete("Filled, not submitted")
        conversation.finished(answer: "Filled, not submitted", ok: true, result: review, from: worker)
        try await wait { TelegramAPI.cards().contains { $0.contains("✅ <b>Done</b>") && $0.contains("Filled, not submitted") } }
        try await wait { TelegramAPI.texts().count == beforeFinish + 1 }
        try await settle()
        check(TelegramAPI.texts().dropFirst(beforeFinish).filter { $0.contains("Filled, not submitted") }.count == 1 && TelegramAPI.texts().count == beforeFinish + 1, "completion: one silent card edit plus one notifying result message")
        check(TelegramAPI.bodies("sendPhoto").count == photosBefore + 1 && (TelegramAPI.bodies("sendPhoto").last?["caption"] as? String)?.hasPrefix("✅ <b>Done</b>") == true, "a card with a thumbnail ends with the final view in the result")
        conversation.handle(message("/result")); try await wait { TelegramAPI.texts().dropFirst(beforeFinish).contains { $0.contains("Field 24") } }
        check(TelegramAPI.texts().dropFirst(beforeFinish).contains { $0.contains("Filled, not submitted") }, "on-demand full result includes status and all answers")

        // Concurrent sessions: browser jobs do not occupy desktop and do not share questions/results.
        let (parallel, desktop, parallelStore) = bridge()
        var browsers: [Agent] = []
        parallel.submitBrowserTask = { [weak parallel] request, files, id in
            guard let parallel else { return false }
            let browser = Agent(); browser.store = parallelStore; browser.selectedFiles = files
            guard parallelStore.start(id) else { return false }
            browsers.append(browser); parallel.attach(browser, taskID: id)
            browser.onFinish = { [weak parallel, weak browser] text, ok in if let browser { parallel?.finished(answer: text, ok: ok, result: nil, from: browser) } }
            browser.submit(request, background: true, taskID: id); return true
        }
        parallel.handle(message("background: read https://example.com/first")); try await wait { browsers.count == 1 }
        parallel.handle(message("background: read https://example.com/second")); try await wait { browsers.count == 2 }
        parallel.handle(message("foreground: open Calculator")); try await wait { desktop.submitted.count == 1 }
        check(browsers.allSatisfy(\.isRunning) && desktop.isRunning && desktop.notes.isEmpty, "two browser tasks and one desktop task stay independent")
        parallel.handle(message("foreground: open TextEdit")); try await wait { parallelStore.queued.count == 1 }
        check(desktop.notes.isEmpty && desktop.submitted.count == 1, "new desktop task queues rather than steering current task")
        desktop.complete("Calculator is open"); try await wait { desktop.submitted.count == 2 }
        check(desktop.submitted[1].contains("TextEdit"), "desktop queue starts when its own controller is free")
        for (index, browser) in browsers.enumerated() {
            browser.question = .init(text: "Question \(index)")
            parallel.ask("Question \(index)", options: ["Answer \(index)"], sensitive: false, from: browser)
        }
        try await wait { TelegramAPI.option("Answer 1") != nil }
        parallel.handle(message("yes")); try await wait { TelegramAPI.texts().contains { $0.contains("More than one task") } }
        check(browsers.allSatisfy { $0.answers.isEmpty }, "ambiguous plain answer cannot reach a random parallel task")
        tap(parallel, TelegramAPI.option("Answer 0")!); check(browsers[0].answers == ["Answer 0"] && browsers[1].answers.isEmpty, "parallel question buttons are task-scoped")
        // A second URL while a question waits is another request, never its answer.
        parallel.handle(message("background: read https://example.com/third")); try await wait { browsers.count == 3 }
        check(browsers[1].answers.isEmpty && browsers[1].notes.isEmpty, "new URL during a question becomes an independent task")
        let stoppedID = browsers[1].taskRecordID!.uuidString.prefix(8)
        parallel.handle(message("/stop \(stoppedID)")); try await wait { !browsers[1].isRunning }
        check(browsers[0].isRunning && browsers[2].isRunning && desktop.isRunning, "stop cancels only its Telegram task")
        let captureCount = desktop.captures
        parallel.handle(message("/screenshot \(String(store.records.first!.id.uuidString.prefix(8)))")); try await settle()
        check(desktop.captures == captureCount, "foreign task IDs cannot capture another controller")
        parallel.handle(message("/stop all")); try await wait { !desktop.isRunning && browsers.allSatisfy { !$0.isRunning } }
        let (foreign, macWorker, _) = bridge(); macWorker.isRunning = true
        foreign.handle(message("/stop")); try await settle(); check(macWorker.isRunning, "Telegram stop never cancels unrelated Mac work")

        // Repeated Telegram delivery, restart review, and no accidental foreground slot reservation.
        let (repeatBot, repeatWorker, _) = bridge()
        let repeated = message("foreground: open Calculator", extra: ["message_id": 777])
        repeatBot.handle(repeated); try await wait { repeatWorker.submitted.count == 1 }
        repeatWorker.complete("Calculator opened")
        repeatBot.handle(repeated); try await settle()
        check(repeatWorker.submitted.count == 1, "duplicate Telegram delivery cannot execute the task twice")

        let (restoredBot, restoredWorker, restoredStore) = bridge()
        let saved = restoredStore.enqueue("open Calculator", source: .telegram, background: false, conversationID: 42)!
        restoredWorker.isRunning = true
        restoredBot.startQueued(saved, reviewed: true)
        check(restoredWorker.submitted.isEmpty && restoredStore.record(saved)?.state == .queued, "reviewed queued request never reserves a busy desktop slot")
        restoredWorker.isRunning = false
        restoredBot.finished(answer: "Other task done", ok: true, result: nil, from: restoredWorker)
        try await wait { restoredWorker.submitted.count == 1 }
        check(restoredWorker.taskRecordID == saved && restoredWorker.modes == [false], "queued request retains its saved mode and task ID")
        restoredWorker.complete()
        let privateTask = restoredStore.enqueue("test-secret", source: .telegram, background: false, conversationID: 42)!
        // The production TaskStore tests exercise redaction; this suite checks review without slot admission.
        check(restoredStore.reviewQueued(privateTask) && restoredStore.record(privateTask)?.state == .queued, "review-only transition does not start work")
        restoredStore.cancelQueued(privateTask)

        let (questionQueue, questionWorker, questionStore) = bridge()
        questionQueue.handle(message("foreground: read the sample form")); try await wait { questionWorker.submitted.count == 1 }
        questionWorker.question = .init(text: "Choose a location")
        questionQueue.ask("Choose a location", options: ["Delhi"], sensitive: false, from: questionWorker)
        questionQueue.handle(message("foreground: open TextEdit")); try await wait { questionStore.queued.count == 1 }
        check(questionWorker.answers.isEmpty && questionWorker.question != nil, "explicit second task cannot answer a pending question")
        questionQueue.handle(message("/stop all")); try await settle()
        check(questionStore.queued.isEmpty && questionWorker.submitted.count == 1, "stop all clears queued Telegram work before handoff")

        let (dedup, dedupWorker, _) = bridge()
        dedup.handle(message("foreground: report a short result")); try await wait { dedupWorker.submitted.count == 1 }
        let doneText = "A unique verified completion answer"
        dedup.present(ResultCard(title: "A short result", text: doneText), from: dedupWorker)
        dedupWorker.complete(doneText)
        try await settle()
        let resultBefore = TelegramAPI.texts().count
        dedup.handle(message("/result"))
        try await wait { TelegramAPI.texts().count > resultBefore }
        let resultText = TelegramAPI.texts().last!
        check(resultText.components(separatedBy: doneText).count == 2, "auto-generated result text appears only once on completion and result replay")
        let (noModeTask, noModeWorker, noModeStore) = bridge()
        noModeTask.handle(message("normal mode")); try await settle()
        check(noModeWorker.submitted.isEmpty && noModeStore.records.isEmpty, "mode-only message cannot create an empty task")

        let (savedBot, savedWorker, savedStore) = bridge()
        let finishedID = savedStore.enqueue("Read a saved result", source: .telegram, background: false, conversationID: 42)!
        check(savedStore.start(finishedID), "saved-result fixture starts")
        savedStore.finish(finishedID, ok: true, answer: "Verified saved outcome")
        let savedBefore = TelegramAPI.texts().count
        savedBot.handle(message("/task \(finishedID.uuidString.prefix(8))"))
        savedBot.handle(message("/result"))
        try await wait { TelegramAPI.texts().dropFirst(savedBefore).filter { $0.contains("Verified saved outcome") }.count == 2 }
        check(TelegramAPI.texts().last!.contains("Succeeded") && TelegramAPI.texts().last!.contains("Normal") && savedWorker.submitted.isEmpty, "selected results survive app restart without a live worker")

        let (missingBot, missingWorker, missingStore) = bridge()
        missingWorker.isRunning = true
        let missing = missingStore.enqueue("read missing attachment", files: [root.appendingPathComponent("no-such-file.pdf")], source: .telegram, background: false, conversationID: 42)!
        missingBot.startQueued(missing, reviewed: true)
        let afterMissing = missingStore.enqueue("open Calculator after missing file", source: .telegram, background: false, conversationID: 42)!
        missingBot.startQueued(afterMissing, reviewed: true)
        missingWorker.isRunning = false
        missingBot.finished(answer: "Mac work complete", ok: true, result: nil, from: missingWorker)
        try await wait { missingWorker.submitted.count == 1 }
        check(missingStore.record(missing)?.state == .failed && missingWorker.taskRecordID == afterMissing, "missing attachment fails cleanly and does not strand the following task")
        missingWorker.complete()

        let (cancelled, cancelledWorker, _) = bridge()
        cancelled.handle(message("foreground: merge", extra: doc("cancel-album").merging(["media_group_id": "cancel"]) { _, v in v }))
        cancelled.handle(message("/stop")); try await Task.sleep(for: .milliseconds(1000))
        check(cancelledWorker.submitted.isEmpty && !TelegramAPI.bodies("getFile").contains { $0["file_id"] as? String == "cancel-album" }, "stop cancels in-flight album ingestion")
        check(Telegram.formKey(url: "a", answers: [("City", "Delhi")]) != Telegram.formKey(url: "a", answers: [("City", "Pune")]), "changed answers invalidate form approval")
        check(Telegram.formKey(url: "a", answers: []) != Telegram.formKey(url: "b", answers: []), "form approval cannot cross pages")
        check(Telegram.intent("Can you send me an image of what you're doing right now?") == .screenshot && Telegram.intent("set the status to available") == nil, "conversational controls do not hijack ordinary task text")
        // A grouped image request has one status card and three requested photos, not four completion messages.
        let (media, coordinator, mediaStore) = bridge()
        media.handle(message("foreground: open 3 tabs and send the first image from each"))
        try await wait { coordinator.submitted.count == 1 }
        let rootID = coordinator.taskRecordID!
        mediaStore.coordinate(rootID)
        var imageWorkers: [Agent] = []
        try await settle()
        let beforeChildren = TelegramAPI.texts().count
        for index in 0..<3 {
            let id = mediaStore.enqueue("Child image goal \(index)", source: .telegram, background: true, conversationID: 42, parentID: rootID)!
            media.registerBrowserTask(id)
            check(mediaStore.start(id), "image child admitted independently")
            let child = Agent(); child.store = mediaStore
            child.onFinish = { [weak media, weak child] text, ok in if let child { media?.finished(answer: text, ok: ok, result: nil, from: child) } }
            media.attach(child, taskID: id); child.submit("Child image goal \(index)", background: true, taskID: id)
            imageWorkers.append(child)
        }
        try await settle()
        check(TelegramAPI.texts().count == beforeChildren, "parallel children never create separate status or completion cards")
        check(imageWorkers.allSatisfy { $0.imageOutputRequirement == 1 }, "parent image delivery requirement is preserved in every child")
        let photosStart = TelegramAPI.bodies("sendPhoto").count
        for (index, child) in imageWorkers.enumerated() {
            let asset = ImageAsset(jpeg: Data("actual-image-\(index)".utf8), source: "https://example.com/\(index).jpg", title: "Image \(index)")
            let delivered = await media.deliverImage(asset, caption: asset.title, from: child)
            check(delivered, "actual image output requires an acknowledged Bot API upload")
            let duplicate = await media.deliverImage(asset, caption: asset.title, from: child)
            check(duplicate, "acknowledged image retry is deduplicated")
            let extra = ImageAsset(jpeg: Data("extra-\(index)".utf8), source: "https://example.com/extra-\(index).jpg", title: "Extra")
            let extraSent = await media.deliverImage(extra, caption: "Not requested", from: child)
            check(!extraSent, "requested photo count prevents extra unsolicited output")
            child.complete("Image \(index) delivered")
        }
        coordinator.complete("All child media returned")
        try await settle()
        check(TelegramAPI.bodies("sendPhoto").count == photosStart + 3 && TelegramAPI.texts().count == beforeChildren + 3 + 1, "three requested images, one parent completion, zero child completion spam")
        check(TelegramAPI.cards().contains { $0.contains("3/3 requested images delivered") && $0.contains("✅ <b>Done</b>") }, "group completion reports acknowledged image counts")
        imageWorkers[0].screenshot = Data("group-task-view".utf8)
        imageWorkers[1].screenshot = Data("group-task-view".utf8)
        imageWorkers[2].screenshot = Data("group-task-view".utf8)
        let screenshotCount = TelegramAPI.bodies("sendPhoto").count
        media.handle(message("/screenshot"))
        try await wait { TelegramAPI.bodies("sendPhoto").count == screenshotCount + 1 }
        check(coordinator.captures == 0 && imageWorkers.reduce(0, { $0 + $1.captures }) == 1, "group screenshot targets a real child tab rather than an empty coordinator")
        let recordCount = mediaStore.records.count
        media.handle(message("What is the progress ?")); try await settle()
        check(mediaStore.records.count == recordCount && TelegramAPI.texts().last!.contains("3/3 requested images delivered"), "natural progress reports parent group without starting another task")
        media.handle(message("/runs")); try await settle()
        check(!imageWorkers.contains { TelegramAPI.texts().last!.contains("#" + String($0.taskRecordID!.uuidString.prefix(8)).lowercased()) } && TelegramAPI.texts().last!.contains("#" + String(rootID.uuidString.prefix(8)).lowercased()), "runs lists parent tasks rather than internal child jobs")

        let (failedMedia, failedWorker, failedStore) = bridge()
        failedMedia.handle(message("foreground: send the first image")); try await wait { failedWorker.submitted.count == 1 }
        let failedAsset = ImageAsset(jpeg: Data("photo".utf8), source: "https://example.com/failure.jpg", title: "Failure fixture")
        let failedStart = TelegramAPI.bodies("sendPhoto").count
        TelegramAPI.lock.withLock { TelegramAPI.failPhotos = true }
        let failedDelivery = await failedMedia.deliverImage(failedAsset, caption: "Fixture", from: failedWorker)
        TelegramAPI.lock.withLock { TelegramAPI.failPhotos = false }
        let uncertainRetry = await failedMedia.deliverImage(failedAsset, caption: "Fixture", from: failedWorker)
        check(!failedDelivery && !uncertainRetry && TelegramAPI.bodies("sendPhoto").count == failedStart + 1, "unacknowledged photo delivery fails closed without blind retry")
        failedWorker.complete("I described the image but did not send it")
        try await settle()
        check(failedStore.record(failedWorker.taskRecordID)?.state == .failed, "description without photo delivery cannot become Succeeded")
        try await wait { TelegramAPI.cards().contains { $0.contains("Image delivery incomplete: 0/1") && $0.contains("❌ <b>Couldn't finish</b>") } }
        check(true, "partial media results are labelled honestly")
        let (analysisOnly, analysisWorker, _) = bridge()
        analysisOnly.handle(message("foreground: describe this image")); try await wait { analysisWorker.submitted.count == 1 }
        let unsolicited = await analysisOnly.deliverImage(failedAsset, caption: "Not requested", from: analysisWorker)
        check(!unsolicited, "image analysis does not authorize unsolicited photo output")
        analysisWorker.complete()
        let (outputs, outputWorker, outputStore) = bridge()
        let ownFile = root.appendingPathComponent("created-screenshot.png")
        try Data("fixture".utf8).write(to: ownFile)
        outputs.handle(message("foreground: capture a local screenshot without sending it"))
        try await wait { outputWorker.submitted.count == 1 }
        outputWorker.outputFiles = [ownFile]
        outputStore.setOutputs(outputWorker.taskRecordID, files: [ownFile])
        outputWorker.complete("Screenshot saved locally")
        check(outputStore.record(outputWorker.taskRecordID)?.outputs == [ownFile.path], "created screenshot path is persisted with its exact task")
        let offerBefore = TelegramAPI.texts().count
        outputs.handle(message("send it on WhatsApp to my own chat"))
        try await wait { outputWorker.submitted.count == 2 }
        check(TelegramAPI.texts().count >= offerBefore && outputWorker.modes.last == true, "follow-up starts directly in the background")
        // Short back-references continue the task the chat just finished: "Submit it", "Apply it in arc", "foreground".
        let (followBot, followWorker, _) = bridge()
        followBot.handle(message("foreground: fill the job form at https://jobs.example/apply/1"))
        try await wait { followWorker.submitted.count == 1 }
        followWorker.complete("Form filled but not submitted: the consent box is still unticked.")
        try await settle()
        followBot.handle(message("Submit it"))
        try await wait { followWorker.submitted.count == 2 }
        check(followWorker.submitted[1].hasPrefix("Submit it") && followWorker.submitted[1].contains("https://jobs.example/apply/1")
              && followWorker.submitted[1].contains("consent box is still unticked"), "“Submit it” carries the earlier request, URL and result")
        followWorker.complete("Stopped", ok: false)
        try await settle()
        followBot.handle(message("Apply it in arc"))
        try await wait { followWorker.submitted.count == 3 }
        check(followWorker.submitted[2].contains("https://jobs.example/apply/1") && followWorker.modes[2] == false, "“Apply it in arc” continues the job in front")
        followWorker.complete("Done")
        try await settle()
        followBot.handle(message("foreground"))
        try await wait { followWorker.submitted.count == 4 }
        check(followWorker.submitted[3].hasPrefix("Apply it in arc") && followWorker.modes[3] == false, "a bare “foreground” re-runs the previous request in front")
        check(outputWorker.selectedFiles == [ownFile] && outputWorker.submitted.last!.contains(ownFile.path), "forwarding follow-up inherits the actual generated screenshot")
        outputWorker.complete("Forwarding test stopped", ok: false)

        // Remote copilot: runs started on the Mac, by a schedule or over MCP get the same card, questions and controls.
        let (mirror, macAgent, mirrorStore) = bridge()
        let macID = mirrorStore.enqueue("Check the order status on example.com", source: .mac, background: true)!
        check(mirrorStore.start(macID), "mirrored fixture starts")
        macAgent.submit("Check the order status on example.com", background: true, taskID: macID)
        RunSupervisor.shared.register(run: macID, source: .scheduled, title: "Check the order status", background: true)
        mirror.mirror(macAgent, taskID: macID, source: .scheduled)
        try await wait { TelegramAPI.texts().contains { $0.contains("from Scheduled") && $0.contains("Check the order status") } }
        check(TelegramAPI.option("Pause") != nil && TelegramAPI.option("Stop") != nil && TelegramAPI.option("Screenshot") != nil, "working card: Pause · Screenshot · Stop")
        let macShort = String(macID.uuidString.prefix(8)).lowercased()
        mirror.handle(message("/runs")); try await wait { TelegramAPI.texts().last?.contains("#" + macShort) == true }
        check(TelegramAPI.texts().last!.contains("from Scheduled"), "/runs lists runs started outside Telegram")
        macAgent.screenshot = Data("mac-run-view".utf8)
        macAgent.question = .init(text: "Cancel the order?")
        let photosBeforeQuestion = TelegramAPI.bodies("sendPhoto").count
        let pending = RunSupervisor.shared.question(run: macID, text: "Cancel the order?", options: ["Yes, go ahead", "No"], sensitive: false) { _ in }
        check(pending.fallback == .option("No"), "timeout default never approves the risky option")
        mirror.ask("Cancel the order?", options: ["Yes, go ahead", "No"], sensitive: false, from: macAgent)
        mirror.ask("Cancel the order?", options: ["Yes, go ahead", "No"], sensitive: false, from: macAgent)
        try await wait { TelegramAPI.texts().contains { $0.contains("Cancel the order?") && $0.contains("No answer in 10 min → I'll choose “No”") } }
        check(TelegramAPI.bodies("sendPhoto").count == photosBeforeQuestion + 1, "question arrives once, with a screenshot of the task target")
        check(TelegramAPI.texts().filter { $0.contains("Cancel the order?") }.count == 1, "duplicate question delivery is ignored")
        tap(mirror, TelegramAPI.option("No")!)
        check(macAgent.answers == ["No"], "option button answers the mirrored run")
        RunSupervisor.shared.answered(run: macID); macAgent.question = nil
        let pauseButton = TelegramAPI.option("Pause")!
        let messagesBeforePause = TelegramAPI.texts().count
        tap(mirror, pauseButton); tap(mirror, pauseButton)
        check(RunSupervisor.shared.state(macID) == .paused, "Pause button pauses the run")
        try await wait { Set(TelegramAPI.toasts().suffix(3)).isSuperset(of: ["Paused", "Already paused"]) }
        check(TelegramAPI.texts().count == messagesBeforePause, "buttons answer with a toast and a silent card edit, not chat messages")
        try await wait { TelegramAPI.cards().contains { $0.contains("⏸ <b>Paused</b>") && $0.contains("#" + macShort) } }
        check(TelegramAPI.option("Resume") != nil && TelegramAPI.option("Take over") != nil, "paused card offers Resume and Take over")
        mirror.handle(message("/resume")); check(RunSupervisor.shared.state(macID) == .running, "/resume continues the selected run")
        mirror.handle(message("/takeover " + macShort)); try await wait { macAgent.reveals == 1 }
        check(RunSupervisor.shared.state(macID) == .takenOver, "/takeover pauses the run and reveals its target")
        let waiter = Task { await RunSupervisor.shared.waitIfPaused(macID, poll: .milliseconds(10)) }
        try await settle()
        mirror.handle(message("/handback"))
        let handBack = await waiter.value
        check(handBack == RunSupervisor.handBackNote && RunSupervisor.shared.state(macID) == .running, "hand back resumes with a note to observe again")
        mirror.handle(message("/stop all")); try await settle()
        check(macAgent.isRunning, "/stop all never stops runs started on the Mac")
        macAgent.complete("Order status checked")
        try await wait { TelegramAPI.cards().contains { $0.contains("✅ <b>Done</b>") && $0.contains("Order status checked") } }
        try await wait { TelegramAPI.texts().contains { $0.contains("Order status checked") && $0.contains("✅") } }
        tap(mirror, pauseButton)
        try await wait { TelegramAPI.toasts().last == "This run has finished" }
        check(RunSupervisor.shared.state(macID) == .running || RunSupervisor.shared.entry(macID) == nil, "stale buttons on a finished run change nothing")
        RunSupervisor.shared.finished(run: macID)
        check(RunSupervisor.shared.entry(macID) == nil, "finished runs leave the registry")

        // Live card: thumbnail refreshes only on meaningful change; replies steer the replied-to run.
        let (live, liveWorker, liveStore) = bridge()
        live.handle(message("background: tidy my downloads folder")); try await wait { liveWorker.submitted.count == 1 }
        let liveID = liveWorker.taskRecordID!, liveShort = String(liveID.uuidString.prefix(8)).lowercased()
        try await wait { TelegramAPI.bodies("sendMessage").contains { ($0["text"] as? String)?.contains("#" + liveShort) == true } }
        let liveCard = TelegramAPI.bodies("sendMessage").last { ($0["text"] as? String)?.contains("#" + liveShort) == true }!
        check(liveCard["parse_mode"] as? String == "HTML" && liveCard["disable_notification"] as? Bool == true, "cards are HTML and silent")
        let liveCardMessage = liveCard["_responseMessageID"] as! Int
        liveWorker.screenshot = Data("live-view-1".utf8); liveWorker.narration = "Sorting <files> & folders"
        liveStore.update(liveID, completedSteps: 3)
        let mediaBefore = TelegramAPI.bodies("editMessageMedia").count
        live.refreshCards()
        try await wait { TelegramAPI.bodies("editMessageMedia").count == mediaBefore + 1 }
        let cardEdit = TelegramAPI.bodies("editMessageMedia").last!
        let mediaCaption = (cardEdit["media"] as? [String: Any])?["caption"] as? String ?? ""
        check(cardEdit["_file_card"] != nil && mediaCaption.contains("step 3") && mediaCaption.contains("Sorting &lt;files&gt; &amp; folders"), "card gets the run's thumbnail with an escaped caption")
        let capturesAfterFirst = liveWorker.captures
        live.refreshCards(); try await settle()
        check(liveWorker.captures == capturesAfterFirst && TelegramAPI.bodies("editMessageMedia").count == mediaBefore + 1, "unchanged state is not re-captured")
        let noteMessage = message("also skip the PDFs", extra: ["message_id": 9001, "reply_to_message": ["message_id": liveCardMessage]])
        live.handle(noteMessage); try await wait { liveWorker.notes.count == 1 }
        try await wait { TelegramAPI.bodies("setMessageReaction").contains { $0["message_id"] as? Int == 9001 } }
        check(liveWorker.notes[0].contains("skip the PDFs"), "a reply to the card adds context to that run, acknowledged with a reaction")
        RunSupervisor.shared.register(run: liveID, source: .telegram, title: "tidy", background: true)
        live.handle(message("pause", extra: ["message_id": 9002, "reply_to_message": ["message_id": liveCardMessage]]))
        try await wait { RunSupervisor.shared.state(liveID) == .paused }
        check(RunSupervisor.shared.state(liveID) == .paused && liveWorker.notes.count == 1, "“pause” replied to the card pauses that run")
        live.handle(message("continue", extra: ["message_id": 9003, "reply_to_message": ["message_id": liveCardMessage]]))
        try await wait { RunSupervisor.shared.state(liveID) == .running }
        check(RunSupervisor.shared.state(liveID) == .running, "“continue” replied to the card resumes it")
        // Skip answers with the safest option; a second tap is idempotent.
        liveWorker.question = .init(text: "Pay for express shipping?")
        live.ask("Pay for express shipping?", options: ["Pay now", "Skip shipping upgrade"], sensitive: false, from: liveWorker)
        try await wait { TelegramAPI.option("Skip") != nil && TelegramAPI.texts().contains { $0.contains("Pay for express shipping?") } }
        let skip = TelegramAPI.option("Skip")!
        tap(live, skip); tap(live, skip)
        check(liveWorker.answers == ["Skip shipping upgrade"], "Skip picks the declining option, once")
        try await wait { Set(TelegramAPI.toasts().suffix(3)).isSuperset(of: ["Skipped", "Nothing to skip right now"]) }
        // Stop twice: one stop, one "already" toast; then Run again exactly once.
        let stopButton = CallbackData.control(liveShort, .stop)
        liveWorker.isRunning = true
        tap(live, stopButton)
        check(!liveWorker.isRunning, "Stop button stops the run")
        tap(live, stopButton)
        try await wait { TelegramAPI.toasts().suffix(3).contains { $0 == "This run has finished" || $0 == "Already stopping" } && TelegramAPI.toasts().suffix(3).contains("Stopping…") }
        try await wait { TelegramAPI.cards().contains { $0.contains("⏹ <b>Stopped</b>") } }
        let again = CallbackData.control(liveShort, .again)
        tap(live, again); tap(live, again)
        try await wait { liveWorker.submitted.count == 2 }
        check(liveWorker.submitted[1].contains("tidy my downloads folder") && liveWorker.modes.last == true, "Run again repeats the request in its mode")
        try await wait { Set(TelegramAPI.toasts().suffix(3)).isSuperset(of: ["Starting again", "Already started again"]) }
        liveWorker.complete("Tidied")

        // Unconfirmed finish: ⚠️ with the screenshot Clinqy saved; produced files come back as documents.
        let (unsure, unsureWorker, _) = bridge()
        unsure.handle(message("foreground: submit the expense form")); try await wait { unsureWorker.submitted.count == 1 }
        let shot = root.appendingPathComponent("unconfirmed.png"); try Data("saved-shot".utf8).write(to: shot)
        let report = root.appendingPathComponent("expenses.csv"); try Data("a,b\n".utf8).write(to: report)
        unsureWorker.outputFiles = [report]
        let photosBeforeUnsure = TelegramAPI.bodies("sendPhoto").count
        unsureWorker.complete("Done — one item I couldn't confirm: submission. The form looked sent. Screenshot: " + shot.path)
        try await wait { TelegramAPI.bodies("sendPhoto").count == photosBeforeUnsure + 1 && !TelegramAPI.bodies("sendDocument").isEmpty }
        let unsurePhoto = TelegramAPI.bodies("sendPhoto").last!
        check((unsurePhoto["_file_photo"] as? Data) == Data("saved-shot".utf8) && (unsurePhoto["caption"] as? String)?.hasPrefix("⚠️ <b>Done — one item I couldn't confirm</b>") == true, "unconfirmed result is ⚠️ with its screenshot")
        check((unsurePhoto["caption"] as? String)?.contains(shot.path) == false, "local screenshot path isn't sent as text")
        check((TelegramAPI.bodies("sendDocument").last?["_file_document"] as? Data) == Data("a,b\n".utf8), "produced file is sent as a document")

        // 429: waits retry_after and delivers once.
        let (limited, limitedWorker, _) = bridge()
        TelegramAPI.lock.withLock { TelegramAPI.rateLimited = 1; TelegramAPI.limitedHits = 0 }
        let welcomes = TelegramAPI.texts().filter { $0 == "You're welcome." }.count
        limited.handle(message("thanks"))
        try await wait { TelegramAPI.texts().filter { $0 == "You're welcome." }.count == welcomes + 1 }
        check(TelegramAPI.lock.withLock { TelegramAPI.limitedHits } == 1 && limitedWorker.submitted.isEmpty, "429 is retried after retry_after")

        // /status overview with tap-to-open cards; /new offers quick replies.
        let (overview, overviewWorker, _) = bridge()
        overview.handle(message("foreground: check the weather")); try await wait { overviewWorker.submitted.count == 1 }
        overviewWorker.isRunning = true
        overview.handle(message("/status")); try await wait { TelegramAPI.texts().last?.contains("1 active run") == true }
        check(TelegramAPI.option("Open card · check the weather") != nil, "overview links each active run's card")
        let deletesBefore = TelegramAPI.bodies("deleteMessage").count
        tap(overview, TelegramAPI.option("Open card · check the weather")!)
        try await wait { TelegramAPI.bodies("deleteMessage").count == deletesBefore + 1 }
        check(TelegramAPI.texts().last?.contains("check the weather") == true, "Open card reposts the card at the bottom")
        Workflows.shared.all = [Workflow(name: "Morning report")]
        overview.handle(message("/new")); try await wait { TelegramAPI.texts().last?.contains("What should I do?") == true }
        let keyboard = (TelegramAPI.bodies("sendMessage").last?["reply_markup"] as? [String: Any])?["keyboard"] as? [[[String: String]]]
        check(keyboard?.first?.first?["text"] == "Morning report" && keyboard?.contains { $0.first?["text"] == "check the weather" } == true, "quick replies offer workflows and recent tasks")
        Workflows.shared.all = []
        overviewWorker.complete()
        try await wait { TelegramAPI.texts().contains { $0.hasPrefix("✅") && $0.contains("check the weather") } }
        try await settle()

        Config.overrides["TELEGRAM_RUNS"] = "telegram"
        let (scoped, scopedAgent, scopedStore) = bridge()
        let scopedID = scopedStore.enqueue("Mac-only work", source: .mac, background: false)!
        _ = scopedStore.start(scopedID)
        scopedAgent.submit("Mac-only work", background: false, taskID: scopedID)
        let beforeScoped = TelegramAPI.texts().count
        scoped.mirror(scopedAgent, taskID: scopedID, source: .mac); try await settle()
        check(TelegramAPI.texts().count == beforeScoped, "TELEGRAM_RUNS=telegram keeps Mac runs out of the chat")
        Config.overrides = [:]
        scopedAgent.complete()
        // Round 5 E6: a short "submit it" after a background Chrome browser job is itself a Chrome browser job.
        check(Telegram.isBrowserJob("submit it", continuing: "In Google Chrome, open http://127.0.0.1:5000/form and fill Name but don't submit."), "follow-up inherits the browser-job lane")
        check(!Telegram.isBrowserJob("submit it", continuing: "In TextEdit, type hello world"), "follow-up of a native task stays on the main agent")
        check(!Telegram.isBrowserJob("submit it"), "without a prior task a bare follow-up is not a browser job")
        do {
            let (laneBot, laneDesktop, laneStore) = bridge()
            var jobs: [(String, Agent)] = []
            laneBot.submitBrowserTask = { [weak laneBot] request, files, id in
                guard let laneBot else { return false }
                let browser = Agent(); browser.store = laneStore
                guard laneStore.start(id) else { return false }
                jobs.append((request, browser)); laneBot.attach(browser, taskID: id)
                browser.onFinish = { [weak laneBot, weak browser] text, ok in if let browser { laneBot?.finished(answer: text, ok: ok, result: nil, from: browser) } }
                browser.submit(request, background: true, taskID: id); return true
            }
            laneBot.handle(message("In Google Chrome, open http://127.0.0.1:5000/form and fill Name with Telegram Retest but don't submit."))
            try await wait { jobs.count == 1 }
            jobs[0].1.complete("Filled Name; not submitted.")
            try await settle()
            laneBot.handle(message("submit it"))
            try await wait { jobs.count == 2 || laneDesktop.submitted.count == 1 }
            check(jobs.count == 2 && laneDesktop.submitted.isEmpty, "Telegram “submit it” continues in an isolated Chrome browser job, not the main agent")
            check(jobs[1].0.hasPrefix("submit it") && jobs[1].0.contains("http://127.0.0.1:5000/form"), "the browser job carries the earlier request and page")
            jobs[1].1.complete("Submitted.")
            try await settle()
        }

        // Round 5 E1: the completion message carries the final view. Order: capture taken as the run finished
        // (before tab cleanup), then a live capture, then the last card thumbnail; photo first, caption = result.
        do {
            let (shotBot, shotWorker, _) = bridge()
            shotBot.handle(message("background: read https://example.com/final")); try await wait { shotWorker.submitted.count == 1 }
            shotWorker.finalShot = Data("final-view".utf8); shotWorker.screenshot = Data("late-live".utf8)
            let capturesBefore = shotWorker.captures, photosBefore = TelegramAPI.bodies("sendPhoto").count
            shotWorker.complete("Read the page.")
            try await wait { TelegramAPI.bodies("sendPhoto").count == photosBefore + 1 }
            let photo = TelegramAPI.bodies("sendPhoto").last!
            check(photo["_file_photo"] as? Data == Data("final-view".utf8) && (photo["caption"] as? String)?.contains("Read the page.") == true, "completion photo is the capture taken before cleanup, with the result as caption")
            check(shotWorker.captures == capturesBefore, "no late capture of a released tab when the final view exists")
            try await settle()
        }
        do {
            let (thumbBot, thumbWorker, _) = bridge()
            thumbBot.handle(message("background: read https://example.com/thumb")); try await wait { thumbWorker.submitted.count == 1 }
            thumbWorker.screenshot = Data("card-thumb".utf8); thumbWorker.narration = "Reading"
            let mediaBefore = TelegramAPI.bodies("editMessageMedia").count
            // The card's first message may still be in flight, so the thumbnail lands as editMessageMedia or as the first sendPhoto.
            let cardPhotosBefore = TelegramAPI.bodies("sendPhoto").count
            _ = thumbBot.refreshCards()
            try await wait { TelegramAPI.bodies("editMessageMedia").count == mediaBefore + 1 || TelegramAPI.bodies("sendPhoto").count == cardPhotosBefore + 1 }
            thumbWorker.screenshot = nil   // the task tab is gone: both the final and the live capture fail
            let photosBefore = TelegramAPI.bodies("sendPhoto").count
            thumbWorker.complete("Read it.")
            try await wait { TelegramAPI.bodies("sendPhoto").count == photosBefore + 1 }
            check(TelegramAPI.bodies("sendPhoto").last?["_file_photo"] as? Data == Data("card-thumb".utf8), "failed final capture falls back to the last card thumbnail")
            try await settle()
        }
        do {
            // A hung final capture is abandoned after the (injected) timeout and the card thumbnail is used.
            let (hangBot, hangWorker, _) = bridge(captureTimeout: 1)
            hangBot.handle(message("background: read https://example.com/hang")); try await wait { hangWorker.submitted.count == 1 }
            hangWorker.screenshot = Data("hang-thumb".utf8); hangWorker.narration = "Reading"
            let mediaBefore = TelegramAPI.bodies("editMessageMedia").count, cardPhotosBefore = TelegramAPI.bodies("sendPhoto").count
            _ = hangBot.refreshCards()
            try await wait { TelegramAPI.bodies("editMessageMedia").count == mediaBefore + 1 || TelegramAPI.bodies("sendPhoto").count == cardPhotosBefore + 1 }
            hangWorker.hangFinal = true; hangWorker.finalShot = Data("never".utf8); hangWorker.screenshot = nil
            let photosBefore = TelegramAPI.bodies("sendPhoto").count
            hangWorker.complete("Read it.")
            try await wait { TelegramAPI.bodies("sendPhoto").count == photosBefore + 1 }
            check(TelegramAPI.bodies("sendPhoto").last?["_file_photo"] as? Data == Data("hang-thumb".utf8), "a hung final capture times out to the card thumbnail")
            try await settle()
        }
        do {
            let (longBot, longWorker, _) = bridge()
            longBot.handle(message("background: read https://example.com/long")); try await wait { longWorker.submitted.count == 1 }
            longWorker.finalShot = Data("long-view".utf8)
            let photosBefore = TelegramAPI.bodies("sendPhoto").count, textsBefore = TelegramAPI.bodies("sendMessage").count
            let long = "Summary: " + String(repeating: "a long line of findings ", count: 90)
            longWorker.complete(long)
            try await wait { TelegramAPI.bodies("sendPhoto").count == photosBefore + 1 && TelegramAPI.bodies("sendMessage").count > textsBefore }
            let photo = TelegramAPI.bodies("sendPhoto").last!, text = TelegramAPI.bodies("sendMessage").last!
            check(photo["_file_photo"] as? Data == Data("long-view".utf8) && (photo["caption"] as? String)?.contains("a long line") == false, "a long result sends the photo first with a short caption")
            check((text["text"] as? String)?.contains("a long line of findings") == true && text["reply_markup"] != nil, "then the full result text with the buttons")
            try await settle()
        }
        print("All Telegram attachment, routing, concurrency and conversation tests passed.")
    }
}
