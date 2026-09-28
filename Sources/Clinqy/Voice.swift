import AVFoundation
import Speech

/// Push-to-talk speech recognition (Apple Speech, on-device when available).
@MainActor
final class Voice: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var error: String?
    /// True while Whisper turns the finished recording into text.
    @Published private(set) var isTranscribing = false

    /// Called with the final transcript when listening stops on its own (silence) or via `stop()`.
    var onFinal: (String) -> Void = { _ in }
    var onLevel: (CGFloat) -> Void = { _ in }
    /// Called when a follow-up listen (`giveUpAfter`) heard nothing and closed the mic.
    var onGaveUp: () -> Void = {}
    /// True while the mic is open only for a possible follow-up after a finished task.
    @Published private(set) var isFollowUp = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// Apple dictation (the live preview) in the user's voice language: Indian English hears Hinglish best.
    private static func recognizer(for language: String) -> SFSpeechRecognizer? {
        let id: String? = switch language {
        case "hinglish": "en-IN"
        case "hi": "hi-IN"
        case "en": Locale.current.region?.identifier == "IN" ? "en-IN" : nil
        case "auto", "": nil
        default: language
        }
        return id.flatMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
            ?? SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }
    private var lastChange = Date()
    private var silenceTimer: Timer?
    private var delivered = false

    /// Speech works only inside the app bundle (it needs the usage strings in Info.plist).
    static var isSupported: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    /// `giveUpAfter`: close the mic quietly if nothing is said within that many seconds (follow-up listening).
    func start(autoStop: Bool = true, giveUpAfter: TimeInterval? = nil) {
        guard !isListening else { return }
        isFollowUp = giveUpAfter != nil
        guard Self.isSupported else { error = "Voice needs the Clinqy app bundle (run ./build.sh run)"; return }
        error = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.error = "Allow Speech Recognition for Clinqy in System Settings → Privacy & Security"
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    Task { @MainActor in
                        if ok { self.begin(autoStop: autoStop, giveUpAfter: giveUpAfter) } else {
                            self.error = "Allow Microphone for Clinqy in System Settings → Privacy & Security"
                        }
                    }
                }
            }
        }
    }

    /// The request the microphone currently feeds; swapped when a new segment starts (read on the audio thread).
    /// Also keeps the whole recording as 16 kHz mono for Whisper.
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var converter: AVAudioConverter?
        private let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        private var samples: [Float] = []

        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { request = r } }

        func reset(inputFormat: AVAudioFormat) {
            lock.withLock {
                samples = []
                samples.reserveCapacity(16_000 * 30)
                converter = AVAudioConverter(from: inputFormat, to: whisperFormat)
            }
        }

        func append(_ b: AVAudioPCMBuffer) {
            let (req, conv) = lock.withLock { (request, converter) }
            req?.append(b)
            guard let conv else { return }
            let ratio = whisperFormat.sampleRate / b.format.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: whisperFormat,
                                             frameCapacity: AVAudioFrameCount(Double(b.frameLength) * ratio) + 32) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return b
            }
            guard err == nil, let ch = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            lock.withLock { samples.append(contentsOf: chunk) }
        }

        func takeSamples() -> [Float] { lock.withLock { defer { samples = [] }; return samples } }
    }
    private let feed = Feed()
    /// Words from segments the recognizer already finalized; the live segment is appended to these.
    private var committed = ""
    private var partial = ""

    private func begin(autoStop: Bool, giveUpAfter: TimeInterval? = nil) {
        recognizer = Self.recognizer(for: Whisper.language)
        guard let recognizer, recognizer.isAvailable else { error = "Speech recognition isn't available right now"; return }
        transcript = ""
        committed = ""
        partial = ""
        delivered = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        let feed = self.feed
        feed.reset(inputFormat: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            feed.append(buffer)
            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(max(1, n)))
            let level = CGFloat(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40)))
            Task { @MainActor in
                guard let self else { return }
                self.level = self.level * 0.6 + level * 0.4
                self.onLevel(self.level)
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        isListening = true
        lastChange = Date()
        startSegment(recognizer)

        silenceTimer?.invalidate()
        let opened = Date()
        if autoStop {
            // Hands-free: stop after a real pause once something has been said.
            silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isListening else { return }
                    if let giveUpAfter, self.transcript.isEmpty, Date().timeIntervalSince(opened) > giveUpAfter {
                        self.cancel()
                        self.onGaveUp()
                        return
                    }
                    guard !self.transcript.isEmpty, Date().timeIntervalSince(self.lastChange) > 2.0 else { return }
                    self.stop()
                }
            }
        }
    }

    /// Starts recognizing a new stretch of speech. The recognizer ends a segment on its own after a pause;
    /// while the user is still talking we keep those words and carry on in a fresh segment.
    private func startSegment(_ recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        request.contextualStrings = NameHints.vocabulary   // the user's people, chats and places
        self.request = request
        feed.set(request)
        partial = ""

        recognition = recognizer.recognitionTask(with: request) { [weak self] result, err in
            Task { @MainActor in
                guard let self, self.request === request else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.partial {
                        self.partial = text
                        self.lastChange = Date()
                        self.updateTranscript()
                    }
                    if result.isFinal {
                        self.commitPartial()
                        if self.isListening { self.startSegment(recognizer) } else { self.deliver() }
                        return
                    }
                }
                if err != nil {
                    self.commitPartial()
                    if self.isListening { self.startSegment(recognizer) } else { self.deliver() }
                }
            }
        }
    }

    private func commitPartial() {
        let p = partial.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { committed = committed.isEmpty ? p : committed + " " + p }
        partial = ""
        updateTranscript()
    }

    private func updateTranscript() {
        let p = partial.trimmingCharacters(in: .whitespaces)
        transcript = p.isEmpty ? committed : (committed.isEmpty ? p : committed + " " + p)
    }

    /// Stops listening and delivers what was heard.
    func stop() {
        guard isListening else { return }
        request?.endAudio()
        // Give the recognizer a moment to finalize the last words (its final result delivers sooner if it comes).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.deliver() }
        teardownAudio()
    }

    func cancel() {
        delivered = true
        recognition?.cancel()
        teardownAudio()
    }

    private func teardownAudio() {
        silenceTimer?.invalidate()
        isFollowUp = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        isListening = false
        level = 0
        onLevel(0)
    }

    private func deliver() {
        guard !delivered else { return }
        delivered = true
        teardownAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        feed.set(nil)
        commitPartial()
        let preview = NameHints.correct(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        let samples = feed.takeSamples()
        guard Whisper.shared.isReady else {
            if !preview.isEmpty { onFinal(preview) }
            return
        }
        // Whisper hears the whole recording at once: better accuracy, punctuation and mixed languages.
        isTranscribing = true
        Task {
            let text = await Whisper.shared.transcribe(samples)
            isTranscribing = false
            let final = text.map(NameHints.correct) ?? preview
            if !final.isEmpty {
                transcript = final
                onFinal(final)
            }
        }
    }
}
