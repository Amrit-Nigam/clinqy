import Foundation

/// Undo for the steps of the current run that can be reversed (typed text → restore the old value, a toggled
/// checkbox → toggle it back, a page navigation → browser back). The agent registers a closure per step as it
/// goes; the command bar shows "Undo" on the latest one. Cleared when a new run starts.
@MainActor
final class StepUndo: ObservableObject {
    static let shared = StepUndo()

    enum Kind: String { case text, toggle, navigation, other }

    struct Entry: Identifiable {
        /// The `Agent.Step.id` this undoes.
        let id: UUID
        let kind: Kind
        /// What undoing does, for the user ("Restore “Amrit” in Full name").
        let label: String
        /// Reverses the step; true when it worked.
        let undo: @MainActor () async -> Bool
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var busy = false

    /// Called by the agent after a reversible step finishes. A later registration for the same step replaces it.
    func register(step: UUID, kind: Kind, label: String, undo: @escaping @MainActor () async -> Bool) {
        entries.removeAll { $0.id == step }
        entries.append(Entry(id: step, kind: kind, label: label, undo: undo))
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
    }

    /// Forgets a step's undo (e.g. a later step made it meaningless: the form was submitted).
    func forget(step: UUID) { entries.removeAll { $0.id == step } }

    func clear() { entries = [] }

    var last: Entry? { entries.last }

    /// Undoes the latest reversible step, notes it in the step list, and tells a running agent about it.
    func undoLast(agent: Agent) async {
        guard let entry = entries.last, !busy else { return }
        busy = true
        defer { busy = false }
        entries.removeLast()
        let ok = await entry.undo()
        Agent.writeLog("  ↩ undo \(entry.kind.rawValue): \(entry.label) — \(ok ? "done" : "failed")")
        agent.steps.append(Agent.Step(text: ok ? "Undone: \(entry.label)" : "Couldn't undo: \(entry.label)", state: ok ? .info : .failed))
        if agent.isRunning, ok {
            agent.addContext("I undid your last step (\(entry.label)). Look again before going on and don't redo it.")
        }
    }
}
