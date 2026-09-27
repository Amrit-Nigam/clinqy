import AppKit
import WhisperKit

/// Local Whisper speech-to-text (WhisperKit, Core ML on Apple silicon). The model is downloaded once into
/// Clinqy's own Application Support folder and loaded while the app runs; nothing leaves the Mac.
@MainActor
final class Whisper: ObservableObject {
    static let shared = Whisper()

    enum State: Equatable { case idle, downloading(Double), loading, ready, failed(String) }
    @Published private(set) var state: State = .idle

    private var kit: WhisperKit?
    private var preparing: Task<Void, Never>?

    /// Large-v3 turbo: near the best Whisper accuracy at a fraction of the cost; override with WHISPER_MODEL.
    static var variant: String { Config.value("WHISPER_MODEL") ?? "large-v3-v20240930_turbo_632MB" }
    static var enabled: Bool { Config.value("VOICE_ENGINE") != "apple" }

    private static let modelsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clinqy/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var isReady: Bool { kit != nil }

    /// The downloaded model folder, if it's complete.
    private static func localModel() -> URL? {
        let repo = modelsDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []
        guard let name = names.first(where: { $0.contains(variant) }) else { return nil }
        let folder = repo.appendingPathComponent(name)
        let parts = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        return parts.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) } ? folder : nil
    }

    var statusText: String? {
        switch state {
        case .downloading(let p): return "Downloading voice model… \(Int(p * 100))%"
        case .loading: return "Loading voice model…"
        case .failed(let why): return "Voice model unavailable (\(why)); using Apple dictation"
        default: return nil
        }
    }

    /// Downloads (first time only) and loads the model in the background.
    func prepare() {
        guard Self.enabled, kit == nil, preparing == nil else { return }
        preparing = Task {
            do {
                // Already on disk: load straight from there (no network, no cache bookkeeping).
                let folder: URL
                if let local = Self.localModel() {
                    folder = local
                } else {
                    state = .downloading(0)
                    folder = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.modelsDir) { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            if case .downloading = Whisper.shared.state { Whisper.shared.state = .downloading(fraction) }
                        }
                    }
                }
                state = .loading
                let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: Self.modelsDir,
                                              verbose: false, logLevel: .error,
                                              prewarm: true, load: true, download: false)
                kit = try await WhisperKit(config)
                state = .ready
            } catch {
                state = .failed(error.localizedDescription.prefix(80).description)
            }
            preparing = nil
        }
    }

    /// Transcribes 16 kHz mono samples. Returns nil if the model isn't ready or heard nothing.
    func transcribe(_ samples: [Float]) async -> String? {
        guard let kit, samples.count > 16_000 / 4 else { return nil }
        // A hint prompt of the user's app and people names helps Whisper spell them ("WhatsApp", not "What's app";
        // "Waje+", not "Vaje Plus"). Whisper keeps the prompt's tail, so remembered names go last.
        var prompt: [Int]?
        if let tokenizer = kit.tokenizer {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                .compactMap(\.cleanName).prefix(20)
            let people = NameHints.promptNames()
            let names = (["Clinqy", "WhatsApp", "YouTube", "Google", "GitHub"] + apps).filter { !people.contains($0) } + people
            prompt = tokenizer.encode(text: " " + names.joined(separator: ", ") + ".")
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let options = DecodingOptions(task: .transcribe, language: nil, temperature: 0,
                                      usePrefillPrompt: true, detectLanguage: true,
                                      skipSpecialTokens: true, withoutTimestamps: true, promptTokens: prompt)
        let results = try? await kit.transcribe(audioArray: samples, decodeOptions: options)
        let text = (results ?? []).map(\.text).joined(separator: " ")
            .replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: "", options: .regularExpression)   // [BLANK_AUDIO], (music)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
