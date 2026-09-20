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
    private var silenceGate = SilenceGate()

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
        silenceGate.reset()
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
        engine.onListening = { [weak self] in
            self?.engineStartedListening()
        }
        engine.onStatus = { [weak self] message in
            self?.statusMessage = message
        }
        Log.speech.info(
            "engine start name=\(String(describing: type(of: engine)), privacy: .public) mode=\(Config.shared.listeningMode.rawValue, privacy: .public)"
        )
        self.engine = engine
        isRunning = true
        do {
            try engine.start()
        } catch {
            Log.speech.info("engine start error=\(error.localizedDescription, privacy: .public)")
            self.engine = nil
            isRunning = false
            throw error
        }
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
        silenceGate.reset()
        engine?.cancel()
        engine = nil
        statusMessage = nil
        isRunning = false
    }

    private func receivePartial(_ text: String) {
        guard isRunning else { return }
        transcript = text
        if !text.isEmpty {
            if Config.shared.listeningMode == .toggle,
               silenceGate.shouldReschedule(partial: text) {
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
        silenceGate.reset()
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
        silenceGate.reset()
        statusMessage = nil
        engine = nil
        if wasRunning {
            onEndedWithoutSpeech?(error)
        }
    }

    private func scheduleSilenceFinalize() {
        scheduleSilenceFinalize(after: Config.shared.silenceTimeout)
    }

    private func engineStartedListening() {
        guard isRunning, Config.shared.listeningMode == .toggle else { return }
        scheduleSilenceFinalize(after: max(Config.shared.silenceTimeout, 4.0))
    }

    private func scheduleSilenceFinalize(after timeout: Double) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: timeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }
    }

    private func hasEndWord(_ text: String) -> Bool {
        guard text.range(
            of: #"\b(do it|execute|send it|over|that's it)[.!?,;]*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            return false
        }
        let prefix = text.replacingOccurrences(
            of: #"\s+(do it|execute|send it|over|that's it)[.!?,;]*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        guard prefix != text else { return false }
        return prefix.split(whereSeparator: { $0.isWhitespace }).count >= 2
    }

    private func stripEndWord(_ text: String) -> String {
        ClauseSplitter.stripTrailingEndWord(text)
    }
}
