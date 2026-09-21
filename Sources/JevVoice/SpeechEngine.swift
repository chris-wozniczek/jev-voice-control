@preconcurrency import AVFoundation
import Combine
import Foundation
import JevVoiceCore
import Speech
import WhisperKit

@MainActor
protocol SpeechEngine: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onListening: (() -> Void)? { get set }
    var onSilence: (() -> Void)? { get set }
    var onStatus: ((String?) -> Void)? { get set }
    var vocabulary: [String] { get set }
    func start() throws
    func finish()
    func cancel()
}

enum WhisperModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case failed(String)
}

private final class WhisperStoreReference: @unchecked Sendable {
    weak var value: WhisperModelStore?

    init(_ value: WhisperModelStore) {
        self.value = value
    }
}

private final class WhisperKitReference: @unchecked Sendable {
    let value: WhisperKit

    init(_ value: WhisperKit) {
        self.value = value
    }
}

@MainActor
final class WhisperModelStore: ObservableObject {
    static let shared = WhisperModelStore()

    struct Model: Identifiable {
        let id: String
        let name: String
        let variant: String
    }

    static let models = [
        Model(id: "openai_whisper-base", name: "Base (fast)", variant: "base"),
        Model(id: "openai_whisper-small", name: "Small (recommended)", variant: "small"),
        Model(
            id: "openai_whisper-large-v3-v20240930_turbo",
            name: "Large-v3 Turbo (best)",
            variant: "large-v3-v20240930_turbo"
        ),
    ]

    @Published private(set) var state: WhisperModelState = .notDownloaded
    @Published private(set) var selectedModel: String
    private var modelPaths: [String: String]
    private var downloadTask: Task<Void, Never>?
    private var loadedKit: WhisperKit?
    private var loadedPath: String?
    private var preloadTask: Task<WhisperKitReference, Error>?
    private var preloadPath: String?

    private init() {
        let defaults = UserDefaults.standard
        selectedModel = defaults.string(forKey: "whisperModel") ?? "openai_whisper-small"
        modelPaths = defaults.dictionary(forKey: "whisperModelPaths") as? [String: String] ?? [:]
        updateState()
    }

    var selected: Model {
        Self.models.first(where: { $0.id == selectedModel }) ?? Self.models[1]
    }

    var isReady: Bool {
        guard let path = modelPaths[selectedModel] else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var selectedPath: String? {
        isReady ? modelPaths[selectedModel] : nil
    }

    var readySizeMB: Int? {
        guard let path = selectedPath,
              let enumerator = FileManager.default.enumerator(atPath: path) else { return nil }
        var bytes: UInt64 = 0
        while let item = enumerator.nextObject() as? String {
            let file = URL(fileURLWithPath: path).appendingPathComponent(item)
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                bytes += UInt64(size)
            }
        }
        return Int((Double(bytes) / 1_000_000).rounded())
    }

    func select(_ model: String) {
        selectedModel = Self.models.contains(where: { $0.id == model }) ? model : Self.models[1].id
        UserDefaults.standard.set(selectedModel, forKey: "whisperModel")
        updateState()
        preload()
    }

    func downloadSelected() {
        guard downloadTask == nil, !isReady else {
            updateState()
            return
        }
        state = .downloading(progress: 0)
        let model = selected
        Log.speech.info("Whisper model loading name=\(model.id, privacy: .public)")
        let modelStore = self
        let storeReference = WhisperStoreReference(self)
        downloadTask = Task { [weak modelStore] in
            do {
                let path = try await WhisperKit.download(
                    variant: model.variant,
                    progressCallback: { progress in
                        Task { @MainActor in
                            storeReference.value?.state = .downloading(
                                progress: progress.fractionCompleted
                            )
                        }
                    }
                )
                guard let modelStore else { return }
                modelStore.modelPaths[model.id] = path.path
                UserDefaults.standard.set(modelStore.modelPaths, forKey: "whisperModelPaths")
                modelStore.downloadTask = nil
                modelStore.state = .ready
                Log.speech.info("Whisper model ready name=\(model.id, privacy: .public)")
                modelStore.preload()
            } catch {
                modelStore?.downloadTask = nil
                modelStore?.state = .failed(error.localizedDescription)
                Log.speech.info(
                    "Whisper model failure name=\(model.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func updateState() {
        state = isReady ? .ready : .notDownloaded
    }

    func preload() {
        guard Config.shared.speechEngine == .whisper,
              isReady,
              let path = selectedPath,
              loadedPath != path else {
            return
        }
        if preloadPath == path, preloadTask != nil {
            return
        }
        preloadTask?.cancel()
        preloadPath = path
        let modelName = selected.id
        let started = Date()
        Log.speech.info("Whisper preload start name=\(modelName, privacy: .public)")
        let task = Task<WhisperKitReference, Error> { [weak self] in
            guard let self else {
                throw SpeechEngineError.message("Whisper model store unavailable")
            }
            return WhisperKitReference(try await self.loadKitUncached(at: path))
        }
        preloadTask = task
        Task { [weak self] in
            do {
                let kit = try await task.value.value
                guard let self, self.preloadPath == path else { return }
                self.loadedKit = kit
                self.loadedPath = path
                let elapsed = Date().timeIntervalSince(started)
                Log.speech.info(
                    "Whisper preload ready name=\(modelName, privacy: .public) elapsed=\(elapsed, privacy: .public)"
                )
            } catch {
                guard let self, self.preloadPath == path else { return }
                Log.speech.info(
                    "Whisper preload failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
            guard let self, self.preloadPath == path else { return }
            self.preloadTask = nil
            self.preloadPath = nil
        }
    }

    func loadKit(at path: String) async throws -> WhisperKit {
        if let loadedKit, loadedPath == path {
            return loadedKit
        }
        if let preloadTask, preloadPath == path {
            let kit = try await preloadTask.value.value
            loadedKit = kit
            loadedPath = path
            return kit
        }
        let kit = try await loadKitUncached(at: path)
        loadedKit = kit
        loadedPath = path
        return kit
    }

    private func loadKitUncached(at path: String) async throws -> WhisperKit {
        try await WhisperKit(modelFolder: path, load: true, download: false)
    }
}

@MainActor
final class AppleSpeechEngine: NSObject, SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onListening: (() -> Void)?
    var onSilence: (() -> Void)?
    var onStatus: ((String?) -> Void)?
    var vocabulary: [String] = []

    private var audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""

    func start() throws {
        cancel()
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechEngineError.message("Speech recognizer unavailable")
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = vocabulary
        self.request = request

        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechEngineError.message("No microphone input available")
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            request.endAudio()
            self.request = nil
            throw error
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.transcript = text
                    if !text.isEmpty {
                        self.onPartial?(text)
                    }
                    if result.isFinal {
                        self.finish()
                    }
                }
                if let error {
                    self.onError?(error)
                }
            }
        }
        onListening?()
    }

    func finish() {
        let text = transcript
        stopEngine()
        onFinal?(text)
    }

    func cancel() {
        stopEngine()
    }

    private func stopEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        recognizer = nil
        transcript = ""
    }
}

@MainActor
final class WhisperSpeechEngine: SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onListening: (() -> Void)?
    var onSilence: (() -> Void)?
    var onStatus: ((String?) -> Void)?
    var vocabulary: [String] = []

    private let store: WhisperModelStore
    private var whisperKit: WhisperKit?
    private var audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var partialTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var transcriptionInFlight = false
    private var transcriptionInFlightIsFinal = false
    private var transcriptionDirty = false
    private var finishing = false
    private var generation = 0
    private var finishTask: Task<Void, Never>?
    private var didLogZeroConversion = false
    private var silenceTask: Task<Void, Never>?
    private var noiseFloor: Double?
    private var noiseFloorSampleCount = 0
    private var voicedSamples = 0
    private var speechStarted = false
    private var lastVoicedAt = Date()
    private var samplesAtLastVoice = 0
    private var samplesAtLastPass = 0
    private var lastPassText = ""
    private var didSignalSilence = false

    init(store: WhisperModelStore? = nil) {
        self.store = store ?? .shared
    }

    func start() throws {
        cancel()
        guard store.isReady, let modelPath = store.selectedPath else {
            throw SpeechEngineError.message(
                "Whisper model not downloaded — open Settings › Hearing"
            )
        }
        finishing = false
        samples = []
        didLogZeroConversion = false
        silenceTask?.cancel()
        silenceTask = nil
        noiseFloor = nil
        noiseFloorSampleCount = 0
        voicedSamples = 0
        speechStarted = false
        lastVoicedAt = Date()
        samplesAtLastVoice = 0
        samplesAtLastPass = 0
        lastPassText = ""
        didSignalSilence = false
        generation += 1
        let currentGeneration = generation
        Log.speech.info("Whisper model loading name=\(self.store.selected.id, privacy: .public)")
        onStatus?("Loading model…")
        try startAudio()
        loadTask = Task { [weak self] in
            do {
                guard let self else { return }
                let kit = try await self.store.loadKit(at: modelPath)
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                self.whisperKit = kit
                Log.speech.info(
                    "Whisper model ready name=\(self.store.selected.id, privacy: .public) audioEncoderCompute=\(kit.modelCompute.audioEncoderCompute.description, privacy: .public) textDecoderCompute=\(kit.modelCompute.textDecoderCompute.description, privacy: .public)"
                )
                self.onStatus?(nil)
                self.loadTask = nil
                if self.finishing {
                    self.finishTask?.cancel()
                    self.finishTask = nil
                    await self.transcribeLatest(
                        isFinal: true,
                        trigger: self.didSignalSilence ? "silence" : "finish"
                    )
                } else {
                    self.onListening?()
                    self.partialTask = Task { [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            guard !Task.isCancelled else { return }
                            await self?.transcribeLatest(isFinal: false, trigger: "partial")
                        }
                    }
                    self.silenceTask = Task { [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            guard !Task.isCancelled, let self,
                                  self.speechStarted,
                                  !self.didSignalSilence,
                                  Date().timeIntervalSince(self.lastVoicedAt) >= Config.shared.silenceTimeout
                            else { continue }
                            self.didSignalSilence = true
                            self.onSilence?()
                        }
                    }
                }
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.loadTask = nil
                self.onStatus?(nil)
                Log.speech.info(
                    "Whisper model failure error=\(error.localizedDescription, privacy: .public)"
                )
                self.onError?(error)
            }
        }
    }

    func finish() {
        finishing = true
        if !transcriptionInFlight {
            partialTask?.cancel()
            partialTask = nil
        }
        silenceTask?.cancel()
        silenceTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        guard whisperKit != nil else {
            let currentGeneration = generation
            finishTask?.cancel()
            finishTask = Task { [weak self] in
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled, let self,
                          self.generation == currentGeneration else { return }
                    if self.whisperKit != nil || self.loadTask == nil { return }
                }
                guard let self, self.generation == currentGeneration else { return }
                self.loadTask?.cancel()
                self.loadTask = nil
                self.generation += 1
                self.onError?(SpeechEngineError.message("Whisper model loading timed out"))
            }
            return
        }
        if transcriptionInFlight {
            if !transcriptionInFlightIsFinal {
                transcriptionDirty = true
            }
        } else {
            Task { [weak self] in
                await self?.transcribeLatest(
                    isFinal: true,
                    trigger: self?.didSignalSilence == true ? "silence" : "finish"
                )
            }
        }
    }

    func cancel() {
        partialTask?.cancel()
        partialTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        loadTask?.cancel()
        loadTask = nil
        finishTask?.cancel()
        finishTask = nil
        generation += 1
        whisperKit = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        converter = nil
        samples = []
        finishing = false
        speechStarted = false
        noiseFloor = nil
        noiseFloorSampleCount = 0
        voicedSamples = 0
        samplesAtLastVoice = 0
        samplesAtLastPass = 0
        lastPassText = ""
        didSignalSilence = false
    }

    private func startAudio() throws {
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        Log.speech.info(
            "whisper audio input sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)"
        )
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw SpeechEngineError.message("No microphone input available")
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpeechEngineError.message("Unable to prepare microphone audio")
        }
        converter.primeMethod = .none
        self.converter = converter
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let floats = Self.convert(buffer, with: converter, to: outputFormat)
            if floats.isEmpty {
                let inputFrames = buffer.frameLength
                if inputFrames > 0 {
                    Task { @MainActor [weak self] in
                        guard let self, !self.didLogZeroConversion else { return }
                        self.didLogZeroConversion = true
                        Log.speech.info(
                            "whisper convert produced 0 frames in=\(inputFrames, privacy: .public)"
                        )
                    }
                }
                return
            }
            Task { @MainActor in self?.append(floats) }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to outputFormat: AVAudioFormat
    ) -> [Float] {
        let capacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate))
        )
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError {
            Log.speech.info(
                "whisper convert error=\(conversionError.localizedDescription, privacy: .public)"
            )
            return []
        }
        guard let data = converted.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(converted.frameLength)))
    }

    private func append(_ floats: [Float]) {
        samples.append(contentsOf: floats)
        let rms = SpeechEnergy.rms(floats)
        noiseFloor = SpeechEnergy.updatedNoiseFloor(current: noiseFloor, rms: rms)
        noiseFloorSampleCount += floats.count
        if SpeechEnergy.isVoiced(rms: rms, noiseFloor: noiseFloor ?? 0.002) {
            voicedSamples += floats.count
            lastVoicedAt = Date()
            samplesAtLastVoice = samples.count
            if voicedSamples >= Int(0.2 * 16_000) {
                speechStarted = true
            }
        }
        let maxSamples = 30 * 16_000
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    nonisolated static func finalText(
        passText: String?,
        failure: Error?,
        lastPartial: String
    ) -> String? {
        if let passText, !passText.isEmpty {
            return passText
        }
        if failure is CancellationError || !lastPartial.isEmpty {
            return lastPartial
        }
        return ""
    }

    private func transcribeLatest(isFinal: Bool, trigger: String) async {
        guard let whisperKit, !samples.isEmpty else {
            if isFinal { onFinal?("") }
            return
        }
        guard isFinal || (!finishing && !didSignalSilence) else { return }
        if transcriptionInFlight {
            transcriptionDirty = true
            return
        }
        guard isFinal || samples.count - samplesAtLastPass >= 8_000 else { return }
        transcriptionInFlight = true
        transcriptionInFlightIsFinal = isFinal
        transcriptionDirty = false
        let audio = samples
        if !isFinal {
            samplesAtLastPass = audio.count
        }
        let started = Date()
        let prompt = "Jev Voice. Apps and names: " + vocabulary.prefix(60).joined(separator: ", ")
        let tokens = whisperKit.tokenizer.map {
            Array($0.encode(text: prompt).prefix(200))
        }
        let languageCode = Config.shared.speechLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let language = languageCode.flatMap {
            Constants.languageCodes.contains($0) ? $0 : nil
        }
        let options = DecodingOptions(
            language: language,
            temperatureFallbackCount: 0,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: tokens,
            logProbThreshold: nil,
            firstTokenLogProbThreshold: nil
        )
        let results = await whisperKit.transcribeWithResults(
            audioArrays: [audio],
            decodeOptions: options
        )
        var text = ""
        var failure: Error?
        if let result = results.first {
            switch result {
            case .success(let segments):
                text = segments.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            case .failure(let error):
                failure = error
                Log.speech.info(
                    "whisper transcribe error=\(error.localizedDescription, privacy: .public)"
                )
            }
        } else {
            failure = SpeechEngineError.message("Whisper returned no transcription result")
            Log.speech.info(
                "whisper transcribe error=\(failure!.localizedDescription, privacy: .public)"
            )
        }
        Log.speech.info(
            "whisper pass final=\(isFinal) trigger=\(trigger, privacy: .public) samples=\(audio.count) text=\(text, privacy: .public) elapsed=\(Date().timeIntervalSince(started), privacy: .public)"
        )
        if failure == nil, text.isEmpty {
            Log.speech.info("whisper transcribe empty samples=\(audio.count)")
        }
        if let failure, isFinal {
            if failure is CancellationError || !lastPassText.isEmpty {
                Log.speech.info("whisper final fallback=lastPartial")
                onFinal?(Self.finalText(
                    passText: nil,
                    failure: failure,
                    lastPartial: lastPassText
                ) ?? "")
            } else {
                onError?(failure)
            }
        } else if isFinal {
            onFinal?(text)
        } else if !text.isEmpty {
            lastPassText = text
            onPartial?(text)
        }
        transcriptionInFlight = false
        transcriptionInFlightIsFinal = false
        if transcriptionDirty {
            await transcribeLatest(
                isFinal: finishing,
                trigger: finishing
                    ? (didSignalSilence ? "silence" : "finish")
                    : "partial"
            )
        }
    }
}

enum SpeechEngineError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
