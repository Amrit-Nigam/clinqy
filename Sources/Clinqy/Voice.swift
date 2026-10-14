import AVFoundation
import Speech

/// Push-to-talk speech recognition, on-device. On macOS 26 the Mac's own speech model (SpeechModel, Transcription)
/// hears it as it's said, so the text is ready a moment after the user stops; before that, or while the model isn't
/// ready, Apple dictation (SFSpeechRecognizer) does.
@MainActor
final class Voice: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var error: String?
    /// True while the speech model finishes the last words after the mic closed.
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
    /// The live transcription by the Mac's speech model (an `@available(macOS 26)` Transcription), while one runs.
    private var transcription: Task<AnyObject?, Never>?

    /// Apple dictation in the user's voice language: Indian English hears Hinglish best.
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
                // The Mac's speech model needs only the microphone; Apple dictation also needs Speech Recognition.
                guard status == .authorized || SpeechModel.shared.isReady else {
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

    /// Where the microphone's audio goes (read on the audio thread): Apple dictation's current request, and/or the
    /// speech model's transcription. Audio that arrives while the transcription is still starting is kept and
    /// handed over once it's ready, so the first word isn't lost.
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var sink: ((AVAudioPCMBuffer) -> Void)?
        private var early: [AVAudioPCMBuffer] = []
        private var holding = false
        private var closed = false

        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { request = r } }

        func reset() { lock.withLock { request = nil; sink = nil; early = []; holding = false; closed = false } }

        /// Keep the audio until `attach`.
        func hold() { lock.withLock { early = []; holding = true } }

        /// Hands the kept audio to `sink`, then sends it whatever comes next (unless the mic already closed).
        func attach(_ sink: @escaping (AVAudioPCMBuffer) -> Void) {
            lock.withLock {
                early.forEach(sink)
                early = []
                holding = false
                if !closed { self.sink = sink }
            }
        }

        /// The mic is off: take no more audio (what was kept stays for a late `attach`).
        func close() { lock.withLock { closed = true; sink = nil } }

        func append(_ b: AVAudioPCMBuffer) {
            lock.withLock {
                guard !closed else { return }
                request?.append(b)
                if let sink { sink(b) } else if holding, let copy = b.copied { early.append(copy) }
            }
        }
    }
    private let feed = Feed()
    /// Words from segments the recognizer already finalized; the live segment is appended to these.
    private var committed = ""
    private var partial = ""

    private func begin(autoStop: Bool, giveUpAfter: TimeInterval? = nil) {
        let native = SpeechModel.shared.isReady
        if !native {
            recognizer = Self.recognizer(for: SpeechModel.language)
            guard let recognizer, recognizer.isAvailable else { error = "Speech recognition isn't available right now"; return }
        }
        transcript = ""
        committed = ""
        partial = ""
        delivered = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        let feed = self.feed
        feed.reset()
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
        if native, #available(macOS 26.0, *) {
            startTranscription()
        } else if let recognizer {
            startSegment(recognizer)
        }

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

    // MARK: The Mac's speech model (macOS 26)

    @available(macOS 26.0, *)
    private func startTranscription() {
        feed.hold()
        let feed = self.feed
        transcription = Task {
            let session = await SpeechModel.shared.start { [weak self] text in
                Task { @MainActor in self?.heard(text) }
            }
            if let session {
                feed.attach(session.feed)
            } else if self.isListening {
                // The model couldn't start: Apple dictation takes over from here.
                self.transcription = nil
                feed.reset()
                self.recognizer = Self.recognizer(for: SpeechModel.language)
                if let recognizer = self.recognizer { self.startSegment(recognizer) }
            }
            return session as AnyObject?
        }
    }

    private func heard(_ text: String) {
        guard isListening, text != transcript else { return }
        transcript = text
        lastChange = Date()
    }

    /// The mic is off: the model finishes the last words (a fraction of a second), then the text is delivered.
    @available(macOS 26.0, *)
    private func finishTranscription(_ pending: Task<AnyObject?, Never>) {
        feed.close()
        teardownAudio()
        transcription = nil
        isTranscribing = true
        Task {
            let session = await pending.value as? Transcription
            let text = await session?.finish() ?? ""
            isTranscribing = false
            guard !delivered else { return }
            delivered = true
            let final = NameHints.correct((text.isEmpty ? transcript : text).trimmingCharacters(in: .whitespacesAndNewlines))
            if !final.isEmpty {
                transcript = final
                onFinal(final)
            }
        }
    }

    // MARK: Apple dictation (before macOS 26, or while the model isn't ready)

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
        if #available(macOS 26.0, *), let transcription {
            finishTranscription(transcription)
            return
        }
        request?.endAudio()
        // Give the recognizer a moment to finalize the last words (its final result delivers sooner if it comes).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.deliver() }
        teardownAudio()
    }

    func cancel() {
        delivered = true
        recognition?.cancel()
        if let transcription {
            self.transcription = nil
            Task {
                if #available(macOS 26.0, *) { (await transcription.value as? Transcription)?.cancel() }
            }
        }
        feed.close()
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
        let final = NameHints.correct(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        if !final.isEmpty { onFinal(final) }
    }
}

private extension AVAudioPCMBuffer {
    /// A copy that outlives the microphone tap's own (reused) buffer.
    var copied: AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(from, to) where src.mData != nil && dst.mData != nil {
            memcpy(dst.mData, src.mData, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        return copy
    }
}
