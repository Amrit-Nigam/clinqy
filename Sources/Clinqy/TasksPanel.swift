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
            panel.setContentSize(NSSize(width: 680, height: 600))
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
    @State private var query = ""
    @State private var unfinishedOnly = false
    private var visible: [TaskStore.Record] {
        store.records.reversed().filter {
            (!unfinishedOnly || $0.state != .succeeded) && (query.isEmpty || $0.request.localizedCaseInsensitiveContains(query) || $0.shortID.contains(query.lowercased()))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tasks & Recovery").font(.title2.bold())
            Text("Review verified outcomes and anything still uncertain. Continuing a task starts with a fresh observation; saved actions are never replayed.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Find a task", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Unfinished", isOn: $unfinishedOnly).toggleStyle(.checkbox)
            }
            if let error = store.storageError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if visible.isEmpty { Text(query.isEmpty ? "No tasks to show." : "No tasks match your search.").foregroundStyle(.secondary) }
                    ForEach(visible) { item in TaskRecordView(store: store, item: item) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(minWidth: 540, minHeight: 400)
    }
}

private struct TaskRecordView: View {
    @ObservedObject var store: TaskStore
    let item: TaskStore.Record
    @State private var showActions = false
    /// Pause state lives in RunSupervisor (not TaskStore); bumping this redraws after a control tap.
    @State private var controlRevision = 0
    private var recoverable: Bool { [.interrupted, .failed, .cancelled].contains(item.state) }
    private var canStart: Bool { (item.background || store.activeForeground == nil) && item.reviewReason?.contains("Private values") != true }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(item.state.label).font(.headline)
                Spacer()
                Text(item.shortID + " · " + item.source.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.request).font(.body.weight(.medium)).lineLimit(5).textSelection(.enabled)
            Text(item.stage).foregroundStyle(.secondary).textSelection(.enabled)
            Text("\(item.completedSteps) completed steps").font(.caption).foregroundStyle(.secondary)
            if let pending = item.pendingAction ?? item.unverifiedAction {
                Label("Outcome needs checking: " + pending + ". No automatic retry.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            if let checklist = item.checklist, !checklist.isEmpty {
                ForEach(checklist) { step in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(step.title, systemImage: step.supersededAt != nil ? "minus.circle" : step.complete ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.supersededAt != nil ? Color.secondary : step.complete ? Color.green : Color.primary)
                        if let evidence = step.evidence { Text(evidence).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let reason = step.supersededReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if !item.openRequirements.isEmpty {
                Text("Still required: " + item.openRequirements.map(\.text).joined(separator: "; ")).font(.caption).textSelection(.enabled)
            }
            if let reason = item.reviewReason { Text(reason).foregroundStyle(.orange) }
            if let result = item.result { Text(result).textSelection(.enabled) }
            if let outputs = item.outputs, !outputs.isEmpty {
                DisclosureGroup("Output files (\(outputs.count))") {
                    ForEach(outputs, id: \.self) { path in Text(path).font(.caption).textSelection(.enabled) }
                }
            }
            DisclosureGroup("Action evidence", isExpanded: $showActions) {
                if showActions {
                    let entries = store.actionHistory(item.id, limit: 50)
                    if entries.isEmpty { Text("No recorded input actions.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.kind + " · " + entry.state.rawValue).font(.caption.weight(.medium))
                            Text(entry.target).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let evidence = entry.evidence { Text(evidence).font(.caption).textSelection(.enabled) }
                        }.padding(.vertical, 3)
                    }
                }
            }
            if let times = item.phaseTimings, !times.isEmpty {
                DisclosureGroup("Timing") {
                    ForEach(times.keys.sorted(), id: \.self) { name in
                        HStack { Text(name.capitalized); Spacer(); Text(String(format: "%.2f s", (times[name] ?? 0) / 1000)) }.font(.caption)
                    }
                    Text("Phases may overlap; total is elapsed task time.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if [.running, .waiting, .needsAttention].contains(item.state), RunSupervisor.shared.entry(item.id) != nil {
                let control = RunSupervisor.shared.state(item.id)
                HStack {
                    if control != .running { Label(control.label, systemImage: control == .paused ? "pause.circle" : "hand.raised").foregroundStyle(.orange) }
                    switch control {
                    case .running:
                        Button("Pause") { command(.pause) }.help("The task waits before its next action; nothing is lost.")
                        Button("Take over") { command(.takeOver) }.help("Pause the task and show its tab or window so you can work in it.")
                    case .paused:
                        Button("Resume") { command(.resume) }
                        Button("Take over") { command(.takeOver) }
                    case .takenOver:
                        Button("Hand back") { command(.handBack) }.help("The task looks at its target again before continuing.")
                    }
                }.id(controlRevision)
            }
            if item.state == .queued {
                HStack {
                    Button(item.requiresReview ? "Reviewed — start task" : "Start task") { store.requestStart(item.id) }.disabled(!canStart)
                    Button("Cancel task") { store.cancelQueued(item.id) }
                }
            } else if recoverable {
                Button("Inspect and continue") { store.requestResume(item.id) }.disabled(!canStart)
                    .help("Continue this request with a fresh observation and its existing verification barriers. This does not replay saved actions.")
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
    private func command(_ command: RunControl.Command) {
        if RunSupervisor.shared.apply(command, to: item.id)?.reveal == true { RunSupervisor.shared.onReveal(item.id) }
        controlRevision += 1
    }
}
