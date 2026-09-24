import AppKit
import SwiftUI

/// Spotlight-style floating panel that doesn't steal focus from the app being controlled.
final class PromptPanel: NSPanel {
    init(orchestrator: Orchestrator, onDismiss: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: PromptView(orchestrator: orchestrator, onDismiss: onDismiss))
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    func showCentered() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - f.height * 0.15))
        }
        makeKeyAndOrderFront(nil)
    }
}

struct PromptView: View {
    @ObservedObject var orchestrator: Orchestrator
    let onDismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: orchestrator.isRunning ? "sparkles" : "cursorarrow.rays")
                    .foregroundStyle(orchestrator.isRunning ? .purple : .blue)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolEffect(.pulse, isActive: orchestrator.isRunning)
                TextField(orchestrator.isRunning ? "Working…" : "Tell CursorBoy what to do", text: $orchestrator.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .disabled(orchestrator.isRunning)
                    .onSubmit {
                        orchestrator.submit(orchestrator.input)
                        orchestrator.input = ""
                    }
                if orchestrator.isRunning {
                    Button("Stop") { orchestrator.cancel() }
                        .keyboardShortcut(".", modifiers: .command)
                } else if !orchestrator.log.isEmpty {
                    Button { orchestrator.clear() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Clear")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if !orchestrator.log.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(orchestrator.log) { line in
                                LogRow(line: line).id(line.id)
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: orchestrator.log.last?.text) {
                        if let last = orchestrator.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 420, minHeight: 56)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            focused = true
        }
    }
}

private struct LogRow: View {
    let line: Orchestrator.LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 14)
            Text(line.text)
                .font(line.kind == .tool ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundStyle(line.kind == .user ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var icon: String {
        switch line.kind {
        case .user: return "person.fill"
        case .info: return "bolt.fill"
        case .tool: return "wrench.and.screwdriver"
        case .agent: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch line.kind {
        case .user: return .primary
        case .info: return .blue
        case .tool: return .orange
        case .agent: return .purple
        case .error: return .red
        case .done: return .green
        }
    }
}
