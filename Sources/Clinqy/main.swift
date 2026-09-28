import AVFoundation
import AppKit

// Clinqy was called CursorBoy: carry its memory, history, skills, workflows, models and settings over once.
do {
    let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    for (old, new) in [(support.appendingPathComponent("CursorBoy"), support.appendingPathComponent("Clinqy")),
                       (home.appendingPathComponent(".config/cursorboy"), home.appendingPathComponent(".config/clinqy")),
                       (home.appendingPathComponent("Library/Logs/CursorBoy"), home.appendingPathComponent("Library/Logs/Clinqy"))]
    where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
        try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: old, to: new)
    }
}

// Terminal run: `Clinqy --run <bundle-id|-> "<task>"` executes the task and prints a timed log.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--run" {
    let args = CommandLine.arguments
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let buddy = Buddy()
        let agent = Agent(buddy: buddy)
        agent.echo = true
        BrowserBridge.shared.start()
        if args[2] != "-" {
            agent.targetApp = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == args[2] }
        }
        agent.onFinish = { _, ok in
            // Stay alive while a mark is on screen so it can be seen.
            let marking = agent.steps.contains { $0.text.hasPrefix("Show ") }
            DispatchQueue.main.asyncAfter(deadline: .now() + (marking ? 5 : 1)) { exit(ok ? 0 : 1) }
        }
        // Give a running browser's extension a moment to connect (it retries every 20 s).
        Task { @MainActor in
            let browserOpen = NSWorkspace.shared.runningApplications.contains { Launcher.isBrowser($0) }
            for _ in 0..<50 where browserOpen && !BrowserBridge.shared.isConnected {
                try? await Task.sleep(for: .milliseconds(500))
            }
            print("extension connected: \(BrowserBridge.shared.isConnected)")
            agent.submit(args[3])
        }
        objc_setAssociatedObject(app, "agent", agent, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(app, "buddy", buddy, .OBJC_ASSOCIATION_RETAIN)
    }
    app.run()
}

// Voice check: `Clinqy --transcribe <audio file>` runs a file through the Whisper model.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--transcribe" {
    let path = CommandLine.arguments[2]
    Task { @MainActor in
        Whisper.shared.prepare()
        while !Whisper.shared.isReady {
            if case .failed(let why) = Whisper.shared.state { print("failed: \(why)"); exit(1) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 64)
        else { print("can't read audio"); exit(1) }
        var fed = false
        converter.convert(to: output, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        let started = Date()
        let text = await Whisper.shared.transcribe(samples) ?? "(nothing)"
        print("\(Int(Date().timeIntervalSince(started) * 1000)) ms: \(text)")
        exit(0)
    }
    RunLoop.main.run()
}

// `--chord [key]`: taps Control+Option like a user (optionally with another key, which must NOT open Clinqy).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--chord" {
    let src = CGEventSource(stateID: .hidSystemState)
    func flags(_ code: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.type = .flagsChanged
        e?.flags = f
        e?.post(tap: .cghidEventTap)
        usleep(40_000)
    }
    flags(0x3B, true, .maskControl)                               // control down
    flags(0x3A, true, [.maskControl, .maskAlternate])             // option down
    if CommandLine.arguments.count >= 3 { AXEngine.press(combo: "ctrl+opt+" + CommandLine.arguments[2]) }
    usleep(120_000)
    flags(0x3A, false, .maskControl)                              // option up
    flags(0x3B, false, [])                                        // control up
    usleep(300_000)
    exit(0)
}

// Test helpers that act like the user (real input events): --click-label <text>, --type <text>, --key <combo>.
if CommandLine.arguments.count >= 3, ["--click-label", "--type", "--key"].contains(CommandLine.arguments[1]) {
    let arg = CommandLine.arguments[2]
    switch CommandLine.arguments[1] {
    case "--click-label":
        guard let app = NSWorkspace.shared.frontmostApplication else { exit(1) }
        // Chromium only builds its web accessibility tree once an assistive client asks for it.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var found: UIElementInfo?
        for _ in 0..<10 where found == nil {
            found = AXEngine.elements(of: app, limit: 600).first { $0.label.lowercased().contains(arg.lowercased()) }
            if found == nil { usleep(300_000) }
        }
        guard let el = found else { print("not found: \(arg)"); exit(1) }
        AXEngine.click(at: el.center)
        print("clicked \(el.role) \(el.label)")
    case "--type": AXEngine.type(arg)
    default: AXEngine.press(combo: arg)
    }
    usleep(300_000)
    exit(0)
}

// `Clinqy --selftest`: fast checks of logic that needs no UI (safety rules, reply parsing).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--selftest" {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }
    check(Safety.needsConfirmation(label: "Pay ₹500", request: "open the checkout page") != nil, "pay needs confirmation")
    check(Safety.needsConfirmation(label: "Pay ₹500", request: "pay for my order") == nil, "pay allowed when asked")
    check(Safety.needsConfirmation(label: "Submit", request: "fill the form but don't submit") != nil, "don't submit is respected")
    check(Safety.needsConfirmation(label: "Send", request: "message mom hi") == nil, "send allowed for a message request")
    check(Safety.needsConfirmation(label: "Delete", request: "open my inbox") != nil, "delete needs confirmation")
    check(Safety.needsConfirmation(label: "Search", request: "anything") == nil, "harmless click passes")
    check(Safety.needsConfirmation(label: "Book now", request: "find flights to mumbai") != nil, "booking needs confirmation")
    check(Safety.isYes("Yes, go ahead") && Safety.isYes("haan") && !Safety.isYes("No"), "yes/no parsing")
    check(MainActor.assumeIsolated { Brain.json(from: "sure {\"say\":\"x\",\"actions\":[]} ok")?["say"] as? String == "x" }, "json in prose")
    check(MainActor.assumeIsolated { (Brain.json(from: "<invoke name=\"look\">")?["actions"] as? [[String: Any]])?.first?["do"] as? String == "look" }, "tool-call tag")
    check(MainActor.assumeIsolated {
        let r = Brain.json(from: "<invoke name=\"scroll\">\n<parameter name=\"dir\">up</parameter>\n</invoke>\n<invoke name=\"scroll\">\n<parameter name=\"dir\">up</parameter>\n</invoke>\n<invoke name=\"look\">\n</invoke>")
        let a = r?["actions"] as? [[String: Any]] ?? []
        return a.count == 3 && a[0]["dir"] as? String == "up" && a[2]["do"] as? String == "look"
    }, "tool-call tags with parameters, several actions")
    check(MainActor.assumeIsolated {
        let a = (Brain.json(from: "<invoke name=\"wait\"><parameter name=\"ms\">800</parameter></invoke>")?["actions"] as? [[String: Any]])?.first
        return a?["ms"] as? Int == 800
    }, "tool-call number parameters")
    // Memory relevance: a maths question gets only core facts; food brings in the Swiggy facts.
    MainActor.assumeIsolated {
        let all = Memory.facts.count
        let math = Memory.relevant(to: "what's 15% of 2400")
        let food = Memory.relevant(to: "order me something to eat")
        if ProcessInfo.processInfo.environment["CB_MEMDUMP"] != nil {
            for (name, r) in [("maths", math), ("food", food), ("apply", Memory.relevant(to: "fill this internship application form"))] {
                print("  [\(name)]"); r.facts.forEach { print("    - \($0.prefix(90))") }
            }
        }
        print("     memory: \(all) facts · maths sends \(math.facts.count) · food sends \(food.facts.count)")
        check(all < 8 || math.facts.count < all / 2, "irrelevant facts are left out")
        check(!Memory.facts.contains { $0.contains("Swiggy") } || food.facts.contains { $0.contains("Swiggy") }, "food request brings in Swiggy facts")
    }
    // Workflows: a saved run turns typed text into a named parameter with the original as default.
    MainActor.assumeIsolated {
        var type = WorkflowStep(action: "type"); type.text = "Amrit Nigam"
        type.target = .init(kind: "web", role: "text", label: "Your name")
        var click = WorkflowStep(action: "click"); click.target = .init(kind: "web", role: "checkbox", label: "Keynote")
        let entry = History.Entry(date: Date(), request: "fill the form", answer: "done", ok: true, steps: [], app: nil,
                                  result: nil, trace: [type, click])
        let wf = Workflow.from(entry)
        check(wf?.params == ["Your name"] && wf?.defaults?["Your name"] == "Amrit Nigam" && wf?.steps[0].text == "{Your name}",
              "saved workflow parameterizes typed text")
        let action = wf?.steps[0].action(params: ["Your name": "Priya"], id: "w5")
        check(action?["text"] as? String == "Priya" && action?["id"] as? String == "w5", "parameters fill in on replay")
    }
    // Workflow-first: a saved run replays for the same request, with typed values read out of the new words.
    MainActor.assumeIsolated {
        var type = WorkflowStep(action: "type"); type.text = "{Your name}"
        type.target = .init(kind: "web", role: "text", label: "Your name")
        var msg = WorkflowStep(action: "type"); msg.text = "{message}"
        let wf = Workflow(name: "Type Amrit Nigam as the name", summary: "", params: ["Your name"], steps: [type], created: Date(),
                          defaults: ["Your name": "Amrit Nigam"])
        let chat = Workflow(name: "message mom I'll be late", summary: "", params: ["message"], steps: [msg], created: Date(),
                            defaults: ["message": "I'll be late"])
        let open = Workflow(name: "open my github profile", summary: "", params: [], steps: [WorkflowStep(action: "open_url", url: "https://github.com")], created: Date())
        let all = [wf, chat, open]
        check(Router.match("type Priya Sharma as the name", in: all)?.params["Your name"] == "Priya Sharma", "workflow-first fills a parameter")
        check(Router.match("Please message mom I'm stuck in traffic.", in: all)?.params["message"] == "I'm stuck in traffic", "workflow-first: filler and punctuation ignored")
        check(Router.match("open my GitHub profile", in: all)?.workflow.name == "open my github profile", "workflow-first: exact request, no parameters")
        check(Router.match("open my github settings", in: all) == nil, "workflow-first: a different request doesn't match")
        check(Router.match("message dad I'll be late", in: all) == nil, "workflow-first: only parameters may differ")
        check(Router.refersToContext("reply to this") && Router.refersToContext("translate it") && !Router.refersToContext("open my github profile"), "requests about \"this\" need the model")
    }
    check(Router.isDismissal("no thanks") && Router.isDismissal("kuch nahi") && Router.isDismissal("bas")
          && !Router.isDismissal("now email that to Rahul"), "follow-up dismissals")
    check(Safety.isYes("haan ji") && Safety.isYes("theek hai") && Safety.isYes("bhej do") && !Safety.isYes("ji nahi") && !Safety.isYes("haan but don't send"),
          "Hinglish yes/no")
    // Dates for the calendar come as local "yyyy-MM-dd HH:mm".
    MainActor.assumeIsolated {
        let d = Events.date("2026-10-02 15:30")
        let c = d.map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
        check(c?.year == 2026 && c?.month == 10 && c?.day == 2 && c?.hour == 15 && c?.minute == 30, "calendar date parsing")
        check(Events.date("2026-10-02") != nil && Events.date("next thursday") == nil, "date-only and nonsense dates")
    }
    // Tables: CSV round-trips quotes, commas and newlines.
    let rows = [["Vendor", "Note", "Amount"], ["Swiggy, Inc", "said \"hi\"\nthen left", "540"]]
    check(Tables.parse(Tables.csv(rows)) == rows, "CSV round trip")
    check(MainActor.assumeIsolated { Files.kindQuery("pdf").contains("com.adobe.pdf") && Files.kindQuery(".key").contains("*.key") }, "file kinds for Spotlight")
    // Scripting dictionaries: Notes should describe its note class and the make command.
    if let notes = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") {
        let sem = DispatchSemaphore(value: 0)
        var dict: String?
        Task.detached {
            let app = try? await NSWorkspace.shared.openApplication(at: notes, configuration: {
                let c = NSWorkspace.OpenConfiguration(); c.activates = false; c.hides = true; return c }())
            if let app { dict = await Scripting.dictionary(for: app) }
            sem.signal()
        }
        sem.wait()
        check(dict?.contains("class note") == true && dict?.contains("make") == true, "Notes dictionary summary (\(dict?.count ?? 0) chars)")
    }
    print(failures == 0 ? "all passed" : "\(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

// `Clinqy --snapshots`: what each connected browser reports for its active tab (debugging the extension).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--snapshots" {
    Task { @MainActor in
        BrowserBridge.shared.start()
        try? await Task.sleep(for: .seconds(23))   // every browser reconnects within 20 s
        for line in await BrowserBridge.shared.debugSnapshots() { print(line) }
        exit(0)
    }
    RunLoop.main.run()
}

// `Clinqy --reload-extension`: reloads the browser extension everywhere it's connected.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--reload-extension" {
    Task { @MainActor in
        BrowserBridge.shared.start()
        try? await Task.sleep(for: .seconds(22))   // browsers reconnect every 20 s
        print("reloaded in \(await BrowserBridge.shared.reloadAll()) browser(s)")
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
