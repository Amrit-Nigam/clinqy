import AppKit
import SwiftUI

@MainActor
final class TasksPanel {
    static let shared = TasksPanel()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let host = NSHostingController(rootView: TasksView(store: .shared))
            let panel = NSWindow(contentViewController: host)
            panel.title = "Tasks & Recovery"
            panel.setContentSize(NSSize(width: 640, height: 560))
            panel.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            panel.isReleasedWhenClosed = false
            window = panel
        }
        window?.center(); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct TasksView: View {
    @ObservedObject var store: TaskStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Tasks & Recovery").font(.title2.bold())
                Text("Interrupted tasks stay stopped. Check what actually happened before sending fresh instructions. Restored queued tasks can be reviewed and started below.")
                    .foregroundStyle(.secondary)
                if let error = store.storageError { Text(error).foregroundStyle(.red) }
                if store.records.isEmpty { Text("No saved tasks yet.").foregroundStyle(.secondary) }
                ForEach(store.records.reversed()) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.state.label).font(.headline)
                            Spacer()
                            Text(item.shortID + " · " + item.source.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.request).font(.body.weight(.medium)).lineLimit(5)
                        Text("Now: " + item.stage).textSelection(.enabled)
                        Text("\(item.completedSteps) steps completed").foregroundStyle(.secondary)
                        if let step = item.lastConfirmedStep { Text("Last confirmed step: " + step) }
                        if let pending = item.pendingAction { Text("Check outcome: " + pending + ". This action will not be replayed automatically.").foregroundStyle(.orange) }
                        if !item.files.isEmpty { Text("Files:\n" + item.files.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                        if let reason = item.reviewReason { Text(reason).foregroundStyle(.orange) }
                        if let result = item.result { Text(result).textSelection(.enabled) }
                        if item.state == .queued {
                            HStack {
                                Button(item.requiresReview ? "Reviewed — start task" : "Start task") { store.requestStart(item.id) }
                                    .disabled((!item.background && store.activeForeground != nil) || item.reviewReason?.contains("Private values") == true)
                                Button("Cancel task") { store.cancelQueued(item.id) }
                            }
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(24)
        }.frame(minWidth: 540, minHeight: 400)
    }
}
