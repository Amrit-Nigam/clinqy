import AVFoundation
import AppKit

// Terminal run: `CursorBoy --run <bundle-id|-> "<task>"` executes the task and prints a timed log.
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

// Voice check: `CursorBoy --transcribe <audio file>` runs a file through the Whisper model.
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

// `CursorBoy --selftest`: fast checks of logic that needs no UI (safety rules, reply parsing).
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
    print(failures == 0 ? "all passed" : "\(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

// `CursorBoy --snapshots`: what each connected browser reports for its active tab (debugging the extension).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--snapshots" {
    Task { @MainActor in
        BrowserBridge.shared.start()
        try? await Task.sleep(for: .seconds(23))   // every browser reconnects within 20 s
        for line in await BrowserBridge.shared.debugSnapshots() { print(line) }
        exit(0)
    }
    RunLoop.main.run()
}

// `CursorBoy --reload-extension`: reloads the browser extension everywhere it's connected.
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
