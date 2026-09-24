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
