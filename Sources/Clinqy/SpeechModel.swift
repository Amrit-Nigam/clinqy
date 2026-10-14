import AppKit

/// The voice language and the Mac's own speech model that hears it (see Transcription). macOS keeps the model
/// (shared with Dictation, Notes and Voice Memos); Clinqy only asks for it once, so it's fetched if this Mac doesn't
/// have it yet. Before macOS 26, and while the model isn't ready, Voice uses Apple dictation (SFSpeechRecognizer).
@MainActor
final class SpeechModel: ObservableObject {
    static let shared = SpeechModel()

    enum State: Equatable { case idle, downloading(Double), ready, failed(String) }
    @Published private(set) var state: State = .idle

    private var preparing: Task<Void, Never>?
    /// The language + model the ready state is for (changing the language means preparing again).
    private var preparedFor: String?

    /// What the user speaks: auto (the Mac's language), en, hinglish (Indian English: Hindi words come out in Latin
    /// letters, the way people text), hi (Hindi), or any locale identifier. Menu → Voice Language, or VOICE_LANGUAGE.
    static var language: String {
        (UserDefaults.standard.string(forKey: "voiceLanguage") ?? Config.value("VOICE_LANGUAGE") ?? "auto")
            .lowercased().trimmingCharacters(in: .whitespaces)
    }

    static let languages: [(code: String, name: String)] = [("auto", "Auto (the Mac's language)"), ("en", "English"), ("hinglish", "Hinglish"), ("hi", "Hindi (हिन्दी)")]

    /// Which of Apple's models hears a language both cover: speech (SpeechTranscriber, the default) or dictation
    /// (DictationTranscriber, the system Dictation's model). VOICE_MODEL in ~/.config/clinqy/env.
    @available(macOS 26.0, *)
    static var preferred: Transcription.Model { Config.value("VOICE_MODEL")?.lowercased() == "dictation" ? .dictation : .speech }

    /// Names worth spelling right: a few well-known apps, the running apps, and the people and chats in memory.
    static var vocabulary: [String] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.cleanName).prefix(20)
        var seen = Set<String>()
        return (NameHints.vocabulary + ["Clinqy", "WhatsApp", "YouTube", "Google", "GitHub"] + apps).filter { seen.insert($0.lowercased()).inserted }
    }

    var isReady: Bool { state == .ready && preparedFor == Self.key }
    private static var key: String { "\(language)|\(Config.value("VOICE_MODEL") ?? "")" }

    var statusText: String? {
        switch state {
        case .downloading(let p): return "Getting the Mac's speech model… \(Int(p * 100))%"
        case .failed(let why): return "Speech model unavailable (\(why)); using Apple dictation"
        default: return nil
        }
    }

    /// Makes sure the model for the current voice language is on this Mac and set aside for Clinqy (macOS fetches
    /// it the first time; after that this takes a moment). Call again after the language changes.
    func prepare() {
        guard #available(macOS 26.0, *), preparing == nil, !isReady else { return }
        let key = Self.key, language = Self.language, preferred = Self.preferred
        preparing = Task {
            if let (locale, model) = await Transcription.choose(language: language, preferred: preferred) {
                do {
                    // Quick when the model is already on the Mac; a download shows its progress in the command bar.
                    try await Transcription.install(model, locale) { fraction in
                        Task { @MainActor in
                            let shared = SpeechModel.shared
                            if shared.state != .ready, fraction < 1 { shared.state = .downloading(fraction) }
                        }
                    }
                    preparedFor = key
                    state = .ready
                } catch {
                    state = .failed(error.localizedDescription.prefix(80).description)
                }
            } else {
                state = .failed("no speech model for \(language)")
            }
            preparing = nil
            if Self.key != key { prepare() }   // the language changed meanwhile
        }
    }

    /// Starts a live transcription in the current voice language, or nil when the Mac's model can't take it.
    @available(macOS 26.0, *)
    func start(onText: @escaping @Sendable (String) -> Void) async -> Transcription? {
        guard isReady, let (locale, model) = await Transcription.choose(language: Self.language, preferred: Self.preferred) else { return nil }
        return try? await Transcription(locale: locale, model: model, vocabulary: Self.vocabulary, onText: onText)
    }
}
