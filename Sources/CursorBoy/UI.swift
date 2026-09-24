import AppKit
import SwiftUI

// MARK: - Windows

/// Spotlight-style command bar. Doesn't activate CursorBoy, so the app being controlled stays frontmost.
final class CommandPanel: NSPanel {
    static let size = NSSize(width: 660, height: 460)

    init(agent: Agent, voice: Voice, onMic: @escaping () -> Void) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = true
        appearance = NSAppearance(named: .darkAqua)
        contentView = NSHostingView(rootView: CommandView(agent: agent, voice: voice, onMic: onMic,
                                                          onClose: { [weak self] in self?.orderOut(nil) }))
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    func showCentered() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - f.height * 0.16))
        }
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; animator().alphaValue = 1 }
    }
}

/// A small click-through status capsule at the top of the screen while CursorBoy works.
final class IslandPanel: NSPanel {
    private var hideWork: DispatchWorkItem?

    init(agent: Agent, voice: Voice) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 60),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
        contentView = NSHostingView(rootView: IslandView(agent: agent, voice: voice))
    }

    override var canBecomeKey: Bool { false }

    func show(for seconds: TimeInterval? = nil) {
        hideWork?.cancel()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 6))
        }
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.orderOut(nil) })
    }
}

private final class Hover: ObservableObject { @Published var on = false }

// MARK: - Design tokens

private enum DS {
    static let corner: CGFloat = 22
    static let hairline = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)

    static func color(_ mood: Buddy.Mood) -> Color { Color(nsColor: Palette.color(for: mood)) }
}

extension Agent.Phase {
    var mood: Buddy.Mood {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .acting: return .acting
        case .waiting: return .idle
        case .done: return .success
        case .failed: return .failure
        }
    }
}

// MARK: - Orb

/// The living dot: breathes when idle, swirls when thinking, swells with your voice.
private struct Orb: View {
    let mood: Buddy.Mood
    var level: CGFloat = 0
    var size: CGFloat = 26

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let base = mood == .idle ? Color(red: 0.58, green: 0.56, blue: 1.0) : DS.color(mood)
            let busy = mood == .thinking || mood == .acting
            let breathe = 1 + 0.05 * sin(t * (busy ? 5 : 1.6))
            let swell = mood == .listening ? 1 + level * 0.45 : 1
            ZStack {
                Circle()
                    .fill(base.opacity(0.28))
                    .scaleEffect(1.25 * swell * breathe)
                    .blur(radius: 6)
                Circle()
                    .fill(AngularGradient(colors: [base, base.opacity(0.35), .white.opacity(0.9), base],
                                          center: .center, angle: .radians(busy ? t * 4 : t * 0.6)))
                    .scaleEffect(breathe * (mood == .listening ? 1 + level * 0.2 : 1))
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .init(x: 0.35, y: 0.3),
                                         startRadius: 0, endRadius: size * 0.5))
            }
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.35), value: mood)
        }
    }
}

// MARK: - Command bar

struct CommandView: View {
    @ObservedObject var agent: Agent
    @ObservedObject var voice: Voice
    @StateObject private var historyTab = Hover()
    @ObservedObject private var whisper = Whisper.shared
    let onMic: () -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    private let suggestions = [
        ("bubble.left.fill", "Say good morning to mom on WhatsApp"),
        ("play.rectangle.fill", "Play lo-fi beats on YouTube"),
        ("moon.fill", "Turn on dark mode"),
        ("note.text", "Make a note: buy milk, eggs, bread"),
    ]

    private var mood: Buddy.Mood { voice.isListening ? .listening : agent.phase.mood }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let q = agent.question {
                    QuestionCard(question: q) { agent.answer($0) }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let earlier = agent.continuation, !agent.isRunning {
                    ContextChip(icon: "arrow.turn.down.right", text: "Continuing: \(earlier.request)") { agent.continuation = nil }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                }
                if let selected = agent.selectedText, !agent.isRunning {
                    SelectionChip(text: selected) { agent.selectedText = nil }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .transition(.opacity)
                }
                bar
                if showBody {
                    Rectangle().fill(DS.hairline).frame(height: 1)
                    content
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                footer
            }
            .background(
                RoundedRectangle(cornerRadius: DS.corner, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: DS.corner, style: .continuous).fill(Color.black.opacity(0.62)))
            )
            .overlay(RoundedRectangle(cornerRadius: DS.corner, style: .continuous).strokeBorder(DS.hairline))
            .clipShape(RoundedRectangle(cornerRadius: DS.corner, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
            .padding(24)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showBody)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: agent.steps.count)
            Spacer(minLength: 0)
        }
        .frame(width: CommandPanel.size.width, height: CommandPanel.size.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }
    }

    private var showBody: Bool { historyTab.on || voice.isTranscribing || whisper.statusText != nil || !agent.steps.isEmpty || !agent.answer.isEmpty || voice.isListening || voice.error != nil || agent.input.isEmpty }

    private var bar: some View {
        HStack(spacing: 14) {
            Orb(mood: mood, level: voice.level)
            ZStack(alignment: .leading) {
                if voice.isListening {
                    Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(voice.transcript.isEmpty ? DS.tertiary : DS.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .contentTransition(.opacity)
                } else if let q = agent.question, q.sensitive {
                    SecureField("", text: $agent.input, prompt: Text("Type it here (kept private)").foregroundStyle(DS.tertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(DS.text)
                        .focused($focused)
                        .onSubmit { agent.answer(agent.input) }
                } else {
                    TextField("", text: $agent.input, prompt: Text(agent.question != nil ? "Your answer" : agent.isRunning ? agent.narration : "What should I do?").foregroundStyle(DS.tertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(DS.text)
                        .focused($focused)
                        .disabled(agent.isRunning && agent.question == nil)
                        .onSubmit { agent.question != nil ? agent.answer(agent.input) : agent.submit(agent.input) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if agent.question != nil {
                IconButton(symbol: voice.isListening ? "waveform" : "mic.fill",
                           tint: voice.isListening ? DS.color(.listening) : DS.secondary, action: onMic)
                    .symbolEffect(.variableColor.iterative, isActive: voice.isListening)
                    .help("Answer by voice")
                IconButton(symbol: "arrow.up", tint: .white) { agent.answer(agent.input) }
            } else if agent.isRunning {
                IconButton(symbol: "stop.fill", tint: .white) { agent.cancel() }
            } else {
                IconButton(symbol: voice.isListening ? "waveform" : "mic.fill",
                           tint: voice.isListening ? DS.color(.listening) : DS.secondary, action: onMic)
                    .symbolEffect(.variableColor.iterative, isActive: voice.isListening)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    @ViewBuilder private var content: some View {
        if historyTab.on && agent.question == nil && !voice.isListening {
            HistoryView(
                onContinue: { entry in
                    agent.continuation = entry
                    historyTab.on = false
                },
                onRunAgain: { entry in
                    historyTab.on = false
                    agent.submit(entry.request)
                },
                onShowResult: { entry in
                    agent.result = entry.result
                    agent.onResult()
                })
        } else {
            mainContent
        }
    }

    @ViewBuilder private var mainContent: some View {
        if let status = whisper.statusText, agent.steps.isEmpty {
            Label(status, systemImage: "waveform.badge.plus").font(.system(size: 12)).foregroundStyle(DS.tertiary)
                .padding(.bottom, 4)
        }
        if voice.isTranscribing {
            Label("Transcribing…", systemImage: "waveform").font(.system(size: 13)).foregroundStyle(DS.secondary)
                .symbolEffect(.variableColor.iterative)
        } else if let error = voice.error {
            Label(error, systemImage: "mic.slash").font(.system(size: 13)).foregroundStyle(DS.secondary)
        } else if voice.isListening {
            Waveform(level: voice.level).frame(height: 26)
        } else if agent.steps.isEmpty && agent.answer.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestions, id: \.1) { icon, text in
                    SuggestionRow(icon: icon, text: text) { agent.submit(text) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if !agent.answer.isEmpty {
                    Text(agent.answer)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DS.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                }
                ForEach(agent.steps.suffix(7)) { step in StepRow(step: step) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Hint(keys: "⌥ Space", text: "open")
            Hint(keys: "hold ⌥ Space", text: "talk")
            Spacer()
            Button { withAnimation(.easeOut(duration: 0.15)) { historyTab.on.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
                    Text(historyTab.on ? "Back" : "History").font(.system(size: 11))
                }
                .foregroundStyle(historyTab.on ? DS.text : DS.tertiary)
            }
            .buttonStyle(.plain)
            Hint(keys: "esc", text: "close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.03))
    }
}

/// What CursorBoy needs from the user, with quick-choice buttons.
private struct QuestionCard: View {
    let question: Agent.Question
    let onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: question.sensitive ? "lock.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Palette.accent))
                Text(question.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.options.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        ChoiceButton(text: option) { onChoose(option) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChoiceButton: View {
    let text: String
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(hover.on ? 0.16 : 0.09)))
                .overlay(Capsule().strokeBorder(Color(nsColor: Palette.accent).opacity(hover.on ? 0.7 : 0.3)))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

/// Lays children out left to right, wrapping onto new lines.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Context riding along with the next request (an earlier run being continued).
private struct ContextChip: View {
    let icon: String
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: Palette.accent))
            Text(text).font(.system(size: 12)).foregroundStyle(DS.secondary).lineLimit(1).truncationMode(.tail)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.tertiary) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The text the user had selected, riding along with the request.
private struct SelectionChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.secondary)
            Text(text.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 12))
                .foregroundStyle(DS.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(text.count) chars").font(.system(size: 10)).foregroundStyle(DS.tertiary)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IconButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(hover.on ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.on)
    }
}

private struct SuggestionRow: View {
    let icon: String
    let text: String
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(DS.tertiary).frame(width: 18)
                Text(text).font(.system(size: 14)).foregroundStyle(hover.on ? DS.text : DS.secondary)
                Spacer()
                Image(systemName: "return").font(.system(size: 11)).foregroundStyle(DS.tertiary).opacity(hover.on ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover.on ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.on)
    }
}

private struct StepRow: View {
    let step: Agent.Step

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                switch step.state {
                case .running: ProgressView().controlSize(.mini).scaleEffect(0.8)
                case .ok: Image(systemName: "checkmark").foregroundStyle(DS.secondary)
                case .failed: Image(systemName: "xmark").foregroundStyle(DS.color(.failure))
                case .info: Image(systemName: "sparkle").foregroundStyle(DS.color(.thinking))
                }
            }
            .font(.system(size: 10, weight: .bold))
            .frame(width: 14)
            Text(step.text)
                .font(.system(size: 13))
                .foregroundStyle(step.state == .running ? DS.text : DS.secondary)
                .lineLimit(1)
        }
        .transition(.opacity.combined(with: .offset(y: 6)))
    }
}

private struct Hint: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(DS.tertiary)
    }
}

private struct Waveform: View {
    let level: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<36, id: \.self) { i in
                    let wave = (sin(t * 7 + Double(i) * 0.45) + 1) / 2
                    Capsule()
                        .fill(DS.color(.listening).opacity(0.85))
                        .frame(width: 3, height: 3 + (4 + level * 22) * wave)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Island

struct IslandView: View {
    @ObservedObject var agent: Agent
    @ObservedObject var voice: Voice

    private var text: String {
        if voice.isListening { return voice.transcript.isEmpty ? "Listening…" : voice.transcript }
        if voice.isTranscribing { return "Transcribing…" }
        if let q = agent.question { return "Needs your input: \(q.text)" }
        return agent.narration.isEmpty ? "Thinking…" : agent.narration
    }

    var body: some View {
        HStack(spacing: 10) {
            Orb(mood: voice.isListening ? .listening : agent.phase.mood, level: voice.level, size: 16)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .truncationMode(voice.isListening ? .head : .tail)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: text)
            if agent.isRunning {
                Text("⌥Space or ⏹ in menu bar stops").font(.system(size: 11)).foregroundStyle(DS.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(DS.hairline))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .frame(width: 560, height: 60)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Result card

/// Floating card on the right that shows what a task produced (options, plans, summaries).
/// Clickable (links, copy, close) but never takes focus from the app being used.
final class ResultPanel: NSPanel {
    static let size = NSSize(width: 420, height: 620)

    init(agent: Agent) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
        contentView = NSHostingView(rootView: ResultView(agent: agent, onClose: { [weak self] in self?.hide() }))
    }

    override var canBecomeKey: Bool { false }

    func show() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.maxX - frame.width - 12, y: f.maxY - frame.height - 12))
        }
        if !isVisible { alphaValue = 0; orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.orderOut(nil) })
    }
}

struct ResultView: View {
    @ObservedObject var agent: Agent
    let onClose: () -> Void
    @StateObject private var copiedFlag = Hover()

    var body: some View {
        VStack(spacing: 0) {
            if let card = agent.result {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(nsColor: Palette.accent))
                        Text(card.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text).lineLimit(2)
                        Spacer(minLength: 8)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(card.plain, forType: .string)
                            copiedFlag.on = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedFlag.on = false }
                        } label: {
                            Image(systemName: copiedFlag.on ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(DS.secondary).help("Copy")
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(DS.secondary).help("Close")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    Rectangle().fill(DS.hairline).frame(height: 1)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if let text = card.text, !text.isEmpty {
                                Text(Self.markdown(text))
                                    .font(.system(size: 13))
                                    .foregroundStyle(DS.text)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.bottom, card.items.isEmpty ? 0 : 4)
                            }
                            ForEach(card.items) { item in ResultItemRow(item: item) }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 540)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.6)))
                )
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.hairline))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .padding(12)
            }
            Spacer(minLength: 0)
        }
        .frame(width: ResultPanel.size.width, height: ResultPanel.size.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct ResultItemRow: View {
    let item: ResultCard.Item
    @StateObject private var hover = Hover()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                if let sub = item.subtitle { Text(sub).font(.system(size: 12)).foregroundStyle(DS.secondary) }
            }
            Spacer(minLength: 8)
            if let detail = item.detail {
                Text(detail).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(nsColor: Palette.accent))
                    .multilineTextAlignment(.trailing)
            }
            if item.link != nil {
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover.on ? 0.09 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { if let link = item.link, let url = URL(string: link) { NSWorkspace.shared.open(url) } }
        .textSelection(.enabled)
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var history = History.shared
    let onContinue: (History.Entry) -> Void
    let onRunAgain: (History.Entry) -> Void
    let onShowResult: (History.Entry) -> Void

    var body: some View {
        if history.entries.isEmpty {
            Text("Nothing yet — your requests will show up here.")
                .font(.system(size: 13)).foregroundStyle(DS.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(history.entries.prefix(60)) { entry in
                        HistoryRow(entry: entry, onContinue: { onContinue(entry) }, onRunAgain: { onRunAgain(entry) },
                                   onShowResult: entry.result == nil ? nil : { onShowResult(entry) },
                                   onDelete: { history.remove(entry) })
                    }
                }
            }
            .frame(maxHeight: 250)
        }
    }
}

private struct HistoryRow: View {
    let entry: History.Entry
    let onContinue: () -> Void
    let onRunAgain: () -> Void
    let onShowResult: (() -> Void)?
    let onDelete: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.ok ? "checkmark.circle" : "xmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(entry.ok ? DS.secondary : DS.color(.failure))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.request).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.text).lineLimit(1)
                Text(entry.answer).font(.system(size: 12)).foregroundStyle(DS.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if hover.on {
                HStack(spacing: 4) {
                    if let onShowResult { SmallButton(title: "Result", action: onShowResult) }
                    SmallButton(title: "Continue", action: onContinue)
                    SmallButton(title: "Run again", action: onRunAgain)
                    Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(DS.tertiary)
                }
            } else {
                Text(entry.date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11)).foregroundStyle(DS.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover.on ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }
}

private struct SmallButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.text)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}
