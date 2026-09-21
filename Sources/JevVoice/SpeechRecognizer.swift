import AVFoundation
import Combine
import Foundation
import JevVoiceCore
import Speech

@MainActor
final class SpeechRecognizer: ObservableObject {
    static let builtInVocabulary = [
        "DeepSeek", "Flash", "Devin", "Claude", "Sonnet", "Opus", "Gemini",
        "Grok", "GPT", "Fusion", "cmux", "oMLX", "Whisper",
    ]

    static func orderedVocabulary(
        extra: [String],
        appNames: [String],
        siteNames: [String] = []
    ) -> [String] {
        var seen = Set<String>()
        return (extra + builtInVocabulary + appNames + siteNames).filter {
            seen.insert($0.lowercased()).inserted
        }
    }

    @Published private(set) var transcript = ""
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?

    var onFinalTranscript: ((String) -> Void)?
    var contextualStrings: [String] = []
    var onEndedWithoutSpeech: ((Error?) -> Void)?
    var frontmostApp: String?
    private(set) var lastFinalTranscript: String?

    private var engine: SpeechEngine?
    private var silenceTimer: Timer?
    private var silenceGate = SilenceGate()
    private var transcriptGeneration = 0
    private var pauseProbeInFlight = false

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
        let engine: SpeechEngine
        switch Config.shared.speechEngine {
        case .apple:
            engine = AppleSpeechEngine()
        case .whisper:
            engine = WhisperSpeechEngine()
        case .appleStreaming:
            if #available(macOS 26, *) {
                engine = SpeechAnalyzerEngine()
            } else {
                engine = AppleSpeechEngine()
            }
        }
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
        engine.onSilence = Config.shared.listeningMode == .toggle
            ? { [weak self] in self?.stop() }
            : nil
        engine.onSpeechPause = Config.shared.listeningMode == .toggle
            && Config.shared.endOfTurnJudgeEnabled
            ? { [weak self] text in
                Task { @MainActor in
                    await self?.judgeEndOfTurn(text: text)
                }
            }
            : nil
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
            transcriptGeneration += 1
            pauseProbeInFlight = false
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
        if !cleaned.isEmpty {
            lastFinalTranscript = cleaned
        }
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

    private func judgeEndOfTurn(text: String) async {
        guard isRunning,
              Config.shared.listeningMode == .toggle,
              Config.shared.endOfTurnJudgeEnabled,
              !pauseProbeInFlight,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        pauseProbeInFlight = true
        let generation = transcriptGeneration
        let started = Date()
        struct State: Encodable {
            let transcript: String
            let previousCommand: String
            let frontmostApp: String?
        }
        let client = JevClient(apiKey: Config.shared.apiKey)
        let questions: [String: Question] = [
            "complete": .noul(
                instructions: "The transcript is a voice command to a computer assistant. Is it a complete command the speaker has finished saying (not cut off mid-phrase, not waiting for an object/argument)?"
            )
        ]
        do {
            let (response, _) = try await client.systemOne(
                state: State(
                    transcript: text,
                    previousCommand: lastFinalTranscript ?? "",
                    frontmostApp: frontmostApp
                ),
                questions: questions
            )
            guard isRunning, generation == transcriptGeneration, transcript == text else { return }
            let probability: Double
            if case .noul(let value) = response.answers["complete"] {
                probability = value
            } else {
                return
            }
            let decision = EndOfTurnPolicy.decide(
                probability: probability,
                silenceTimeout: Config.shared.silenceTimeout
            )
            let decisionName: String
            switch decision {
            case .finalize:
                decisionName = "finalize"
                stop()
            case .wait(let timeout):
                decisionName = "wait"
                engine?.silenceTimeoutOverride = timeout
                scheduleSilenceFinalize(after: timeout)
            case .timer:
                decisionName = "timer"
            }
            Log.speech.info(
                "eot judge p=\(probability) elapsed=\(Int(Date().timeIntervalSince(started) * 1000))ms decision=\(decisionName, privacy: .public) chars=\(text.count)"
            )
        } catch {
            Log.speech.info(
                "eot judge error=\(error.localizedDescription, privacy: .public) elapsed=\(Int(Date().timeIntervalSince(started) * 1000))ms decision=timer chars=\(text.count)"
            )
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
