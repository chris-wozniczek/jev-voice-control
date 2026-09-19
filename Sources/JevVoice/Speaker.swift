@preconcurrency import AVFoundation
import Combine

@MainActor
protocol VoiceEngine: AnyObject {
    var name: String { get }
    func speak(_ text: String) async
    func stop()
}

@MainActor
final class AppleVoiceEngine: NSObject, VoiceEngine, AVSpeechSynthesizerDelegate {
    let name = "Apple"
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        guard !text.isEmpty else { return }
        stop()
        let config = Config.shared
        let voice = config.voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: nil)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = config.speechRate
        synthesizer.speak(utterance)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
    }

    func stop() {
        guard synthesizer.isSpeaking else {
            continuation?.resume()
            continuation = nil
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.finish() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.finish() }
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class Speaker: ObservableObject {
    static let shared = Speaker()

    @Published private(set) var isSpeaking = false
    var engine: VoiceEngine = AppleVoiceEngine()

    func say(_ text: String) async {
        isSpeaking = true
        defer { isSpeaking = false }
        await engine.speak(text)
    }

    func stop() {
        engine.stop()
        isSpeaking = false
    }
}
