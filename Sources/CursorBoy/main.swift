import AppKit

// Dry run: `CursorBoy --dry <bundle-id> "<task>" [history...]` prints Jev's next action without acting.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--dry" {
    let args = CommandLine.arguments
    guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == args[2] }) else {
        print("app not running"); exit(1)
    }
    Task { @MainActor in
        let started = Date()
        let elements = AXEngine.elements(of: target, limit: 150)
        let focus = AXEngine.focusSummary(of: target)
        let spans = Orchestrator.textSpans(of: args[3])
        do {
            let d = try await Orchestrator.decideNext(task: args[3], app: target, elements: elements, focus: focus,
                                                      spans: spans, history: Array(args.dropFirst(4)))
            var meaning = d.key
            if d.key.hasPrefix("click_"), let i = Int(d.key.dropFirst(6)) { meaning = "click \(elements[i].role): \(elements[i].label)" }
            if d.key.hasPrefix("type_"), let i = Int(d.key.dropFirst(5)) {
                let field = try await Orchestrator.chooseField(text: spans[i], task: args[3], elements: elements)
                meaning = "type \"\(spans[i])\" into \(field.map { elements[$0.index].label } ?? "-")  (check \(field?.ok ?? 0))"
            }
            print("\(elements.count) elements, focus=\(focus.focused)")
            print("→ \(meaning)  p=\(d.probability) done=\(d.done) absent=\(d.absent)  \(Int(Date().timeIntervalSince(started) * 1000))ms")
            if Planner.isAvailable {
                let t = Date()
                let image = await Screenshot.annotated(app: target, elements: elements)
                if let image, let out = ProcessInfo.processInfo.environment["CB_SHOT"] {
                    try? Data(base64Encoded: image)?.write(to: URL(fileURLWithPath: out))
                }
                print("screenshot: \(image == nil ? "none (Screen Recording off?)" : "\(image!.count / 1024) KB")  \(Int(Date().timeIntervalSince(t) * 1000))ms")
                let pl = try await Planner.plan(task: args[3], app: target.localizedName ?? "?", focused: focus.focused,
                                                history: [], elements: elements, screenshot: image)
                print("PLAN (\(Int(Date().timeIntervalSince(t) * 1000))ms): " + pl.steps.map(\.summary).joined(separator: " → ") + "  // \(pl.reason)")
                let g = try await Planner.nextStep(task: args[3], app: target.localizedName ?? "?", focused: focus.focused,
                                                   history: Array(args.dropFirst(4)), elements: elements, screenshot: image)
                let el = g.element.map { elements[$0].label } ?? "-"
                print("GPT → \(g.kind.rawValue) \(el.prefix(60)) text=\(g.text ?? "-") key=\(g.key ?? "-")  \(Int(Date().timeIntervalSince(t) * 1000))ms  (\(g.reason))")
            }
        } catch {
            print("error: \(error)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

// Routing check: `CursorBoy --route "<task>"...` prints which app each task would switch to.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--route" {
    Task { @MainActor in
        let o = Orchestrator(buddy: BuddyCursor())
        o.echo = true
        o.targetApp = NSWorkspace.shared.frontmostApplication
        for task in CommandLine.arguments.dropFirst(2) {
            let url = await o.routeApp(task)
            print("\(task)  →  \(url?.deletingPathExtension().lastPathComponent ?? "stay")")
        }
        exit(0)
    }
    NSApplication.shared.run()
}

// Real run from the terminal: `CursorBoy --run <bundle-id|-> "<task>"` executes the task and prints a timed log.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--run" {
    let args = CommandLine.arguments
    let nsApp = NSApplication.shared
    nsApp.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let buddy = BuddyCursor()
        let orchestrator = Orchestrator(buddy: buddy)
        orchestrator.echo = true
        if args[2] != "-" {
            orchestrator.targetApp = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == args[2] }
        }
        orchestrator.submit(args[3])
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !orchestrator.isRunning { exit(0) }
            }
        }
        // Keep buddy alive for the whole run.
        objc_setAssociatedObject(nsApp, "buddy", buddy, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(nsApp, "orch", orchestrator, .OBJC_ASSOCIATION_RETAIN)
    }
    nsApp.run()
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
