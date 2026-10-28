import AVFoundation
import ObjCCatch
import Speech

/// One stretch of speech turned into text by the Mac's own speech models (SpeechAnalyzer, macOS 26) while it's
/// being said: `feed` it the microphone's buffers, watch the text grow through `onText`, and `finish()` for the
/// final text. The models belong to the system (shared with Notes, Voice Memos and Dictation, kept up to date by
/// macOS), so nothing is downloaded into Clinqy and nothing is held in its memory between requests.
/// Self-contained on purpose: the speech benchmark compiles this exact file.
@available(macOS 26.0, *)
final class Transcription: @unchecked Sendable {
    /// `speech` is SpeechTranscriber, Apple's newer model; `dictation` is DictationTranscriber, the system Dictation's
    /// model, which also covers languages SpeechTranscriber doesn't (Hindi among them).
    enum Model: String, Sendable { case speech, dictation }

    enum Failure: LocalizedError {
        case unsupported(String), notInstalled(Locale)
        var errorDescription: String? {
            switch self {
            case .unsupported(let language): return "The Mac has no speech model for \(language)"
            case .notInstalled(let locale): return "The speech model for \(locale.identifier) isn't downloaded yet"
            }
        }
    }

    let locale: Locale
    let model: Model
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var results: Task<String, Never>?

    // MARK: Choosing a model

    /// The locale a voice-language setting means: auto (the Mac's own), en, hinglish (Indian English, so Hindi words
    /// come out in Latin letters the way people type them), hi, or any locale identifier.
    static func locale(for language: String) -> Locale {
        let current = Locale.current
        switch language {
        case "auto", "": return current
        case "en":
            if current.region?.identifier == "IN" { return Locale(identifier: "en-IN") }
            return current.language.languageCode?.identifier == "en" ? current : Locale(identifier: "en-US")
        case "hinglish": return Locale(identifier: "en-IN")
        case "hi": return Locale(identifier: "hi-IN")
        default: return Locale(identifier: language)
        }
    }

    /// The model and exact locale that serve `language`: `preferred` first when it has that language, else the other.
    static func choose(language: String, preferred: Model = .speech) async -> (locale: Locale, model: Model)? {
        let wanted = locale(for: language)
        for model in preferred == .speech ? [Model.speech, .dictation] : [.dictation, .speech] {
            if let found = await supported(model, wanted) { return (found, model) }
        }
        return nil
    }

    /// `supportedLocale(equivalentTo:)` can name a locale the model doesn't list (SpeechTranscriber answers hi-IN),
    /// so the answer is checked against the list.
    private static func supported(_ model: Model, _ locale: Locale) async -> Locale? {
        let found: Locale?, all: [Locale]
        switch model {
        case .speech:
            guard SpeechTranscriber.isAvailable else { return nil }
            found = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            all = await SpeechTranscriber.supportedLocales
        case .dictation:
            found = await DictationTranscriber.supportedLocale(equivalentTo: locale)
            all = await DictationTranscriber.supportedLocales
        }
        guard let found else { return nil }
        let id = found.identifier(.bcp47)
        return all.contains { $0.identifier(.bcp47) == id } ? found : nil
    }

    private static func module(_ model: Model, _ locale: Locale, live: Bool) -> any SpeechModule {
        switch model {
        case .speech:
            // Volatile results are the live preview; the final text comes from the full-accuracy pass.
            return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                     reportingOptions: live ? [.volatileResults] : [], attributeOptions: [])
        case .dictation:
            // Apple's progressiveShortDictation preset when live: without frequent finalization the last words
            // are never marked final.
            return DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                                        reportingOptions: live ? [.volatileResults, .frequentFinalization] : [], attributeOptions: [])
        }
    }

    /// Whether the model for `locale` is on this Mac already (`installed`), can be fetched, or isn't offered.
    static func status(_ model: Model, _ locale: Locale) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [module(model, locale, live: false)])
    }

    /// Has macOS download the model for `locale` if it isn't there yet (once; it's shared with the rest of the system).
    static func install(_ model: Model, _ locale: Locale, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module(model, locale, live: false)]) else { return }
        let watch = progress.map { report in
            request.progress.observe(\.fractionCompleted) { p, _ in report(p.fractionCompleted) }
        }
        defer { watch?.invalidate() }
        try await request.downloadAndInstall()
    }

    // MARK: A session

    /// Starts listening for audio. `vocabulary` (names of people, chats, apps) steers how they're spelled; `onText`
    /// gets the whole text so far (finished parts plus the live guess) each time it changes, on a background task.
    init(locale: Locale, model: Model, live: Bool = true, vocabulary: [String] = [],
         onText: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        self.locale = locale
        self.model = model
        let module = Self.module(model, locale, live: live)
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw Failure.notInstalled(locale) }
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        // Lingering: the model stays warm between requests a little while, then the system lets it go.
        analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.input = input
        results = Task {
            // Finished stretches, then the newest guess at the stretch still open. A model can end without marking
            // its last stretch final, so that guess counts too.
            var done = "", open = ""
            func heard(_ text: String, final: Bool) {
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if final { done = Self.join(done, text); open = "" } else { open = text }
                onText(Self.join(done, open))
            }
            do {
                switch module {
                case let m as SpeechTranscriber: for try await r in m.results { heard(String(r.text.characters), final: r.isFinal) }
                case let m as DictationTranscriber: for try await r in m.results { heard(String(r.text.characters), final: r.isFinal) }
                default: break
                }
            } catch {}
            return Self.join(done, open)
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            input.finish()
            results?.cancel()
            throw error
        }
    }

    private static func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : b.isEmpty ? a : a + " " + b }

    /// Hands audio over (any format; it's converted to what the model takes). Call from one thread at a time,
    /// such as the microphone tap. The buffer may be reused once this returns.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        convert(with: converter, buffer)
    }

    private func convert(with converter: AVAudioConverter, _ buffer: AVAudioPCMBuffer?) {
        let frames = buffer.map { Double($0.frameLength) * format.sampleRate / $0.format.sampleRate } ?? 0
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.rounded(.up)) + 1024) else { return }
        var given = false
        var error: NSError?
        // A format the converter can't take raises an Objective-C exception on the audio thread; drop that buffer.
        let failure = ObjCCatch {
            converter.convert(to: out, error: &error) { _, status in
                // nil buffer = the end: flush what the resampler still holds.
                guard let buffer, !given else { status.pointee = buffer == nil ? .endOfStream : .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return buffer
            }
        }
        if failure == nil, error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    /// No more audio: returns the final text once the model has finished with everything it was given.
    func finish() async -> String {
        if let converter { convert(with: converter, nil) }
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        return await results?.value ?? ""
    }

    /// Drops the session without waiting for text.
    func cancel() {
        input.finish()
        results?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}
