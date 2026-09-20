import AVFoundation
import Combine
import Foundation
import JevVoiceCore
import Speech

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?

    var onFinalTranscript: ((String) -> Void)?
    var contextualStrings: [String] = []
    var onEndedWithoutSpeech: ((Error?) -> Void)?

    private var engine: SpeechEngine?
    private var silenceTimer: Timer?

    static func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        cancel()
        transcript = ""
        let engine: SpeechEngine = Config.shared.speechEngine == .whisper
            ? WhisperSpeechEngine()
            : AppleSpeechEngine()
        engine.vocabulary = contextualStrings
        engine.onPartial = { [weak self] text in
            self?.receivePartial(text)
        }
        engine.onFinal = { [weak self] text in
            self?.receiveFinal(text)
        }
        engine.onError = { [weak self] error in
            self?.receiveError(error)
        }
        engine.onStatus = { [weak self] message in
            self?.statusMessage = message
        }
        Log.speech.info(
            "engine start name=\(String(describing: type(of: engine)), privacy: .public) mode=\(Config.shared.listeningMode.rawValue, privacy: .public)"
        )
        do {
            try engine.start()
        } catch {
            Log.speech.info("engine start error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
        self.engine = engine
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        silenceTimer?.invalidate()
        silenceTimer = nil
        engine?.finish()
    }

    func cancel() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        engine?.cancel()
        engine = nil
        statusMessage = nil
        isRunning = false
    }

    private func receivePartial(_ text: String) {
        guard isRunning else { return }
        transcript = text
        if !text.isEmpty {
            if Config.shared.listeningMode == .toggle {
                scheduleSilenceFinalize()
            }
            if hasEndWord(text) {
                stop()
            }
        }
    }

    private func receiveFinal(_ text: String) {
        isRunning = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        statusMessage = nil
        let cleaned = stripEndWord(text)
        Log.speech.info("final transcript=\(cleaned, privacy: .public)")
        transcript = cleaned
        engine = nil
        if cleaned.isEmpty {
            onEndedWithoutSpeech?(nil)
        } else {
            onFinalTranscript?(cleaned)
        }
    }

    private func receiveError(_ error: Error) {
        Log.speech.info("recognition error=\(error.localizedDescription, privacy: .public)")
        let wasRunning = isRunning
        isRunning = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        statusMessage = nil
        engine = nil
        if wasRunning {
            onEndedWithoutSpeech?(error)
        }
    }

    private func scheduleSilenceFinalize() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: Config.shared.silenceTimeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }
    }

    private func hasEndWord(_ text: String) -> Bool {
        text.range(
            of: #"\b(go|do it|execute|send it|over)[.!?,;]*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func stripEndWord(_ text: String) -> String {
        ClauseSplitter.stripTrailingEndWord(text)
    }
}
