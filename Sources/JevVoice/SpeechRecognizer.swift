import AVFoundation
import os
import Speech

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRunning = false

    var onFinalTranscript: ((String) -> Void)?
    var contextualStrings: [String] = []
    /// Called when recognition ends without a usable transcript, with the
    /// underlying error if the system reported one.
    var onEndedWithoutSpeech: ((Error?) -> Void)?
    private let log = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "speech")

    private var audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var heardSpeech = false

    static func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }
        if #available(macOS 14, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() throws {
        stop(fireCallback: false)
        transcript = ""
        heardSpeech = false

        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "JevVoice.Speech", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"]
            )
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = contextualStrings
        self.request = request

        // A fresh engine picks up the current default input device and the
        // microphone permission granted since the last attempt.
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.request = nil
            throw NSError(
                domain: "JevVoice.Speech", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No microphone input available"]
            )
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.request = nil
            throw error
        }
        isRunning = true
        log.info("listening: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, onDevice=\(recognizer.supportsOnDeviceRecognition, privacy: .public)")

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.log.debug("partial: \(text.count, privacy: .public) chars")
                    self.transcript = text
                    if !text.isEmpty {
                        self.heardSpeech = true
                        self.scheduleSilenceFinalize()
                    }
                    if result.isFinal { self.stop(fireCallback: true) }
                }
                if let error {
                    self.log.error("recognition error: \(error.localizedDescription, privacy: .public)")
                    self.stop(fireCallback: true, error: error)
                }
            }
        }
    }

    func stop() {
        stop(fireCallback: true)
    }

    private func stop(fireCallback: Bool, error: Error? = nil) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard isRunning || task != nil else { return }
        isRunning = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        guard fireCallback else { return }
        if heardSpeech, !transcript.isEmpty {
            onFinalTranscript?(transcript)
        } else {
            onEndedWithoutSpeech?(error)
        }
    }

    private func scheduleSilenceFinalize() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.stop(fireCallback: true) }
        }
    }
}
