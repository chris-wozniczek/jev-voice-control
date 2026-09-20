@preconcurrency import AVFoundation
import Combine
import Foundation
import Speech
import WhisperKit

@MainActor
protocol SpeechEngine: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
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

    func loadKit(at path: String) async throws -> WhisperKit {
        if let loadedKit, loadedPath == path {
            return loadedKit
        }
        let kit = try await WhisperKit(modelFolder: path, load: true, download: false)
        loadedKit = kit
        loadedPath = path
        return kit
    }
}

@MainActor
final class AppleSpeechEngine: NSObject, SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
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
    private var transcriptionDirty = false
    private var finishing = false

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
        Log.speech.info("Whisper model loading name=\(self.store.selected.id, privacy: .public)")
        onStatus?("Loading model…")
        loadTask = Task { [weak self] in
            do {
                guard let self else { return }
                let kit = try await self.store.loadKit(at: modelPath)
                self.whisperKit = kit
                Log.speech.info("Whisper model ready name=\(self.store.selected.id, privacy: .public)")
                self.onStatus?(nil)
                try self.startAudio()
                self.partialTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        guard !Task.isCancelled else { return }
                        await self?.transcribeLatest(isFinal: false)
                    }
                }
            } catch {
                self?.onStatus?(nil)
                Log.speech.info(
                    "Whisper model failure error=\(error.localizedDescription, privacy: .public)"
                )
                self?.onError?(error)
            }
        }
    }

    func finish() {
        finishing = true
        partialTask?.cancel()
        partialTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        Task { [weak self] in
            await self?.transcribeLatest(isFinal: true)
        }
    }

    func cancel() {
        partialTask?.cancel()
        partialTask = nil
        loadTask?.cancel()
        loadTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        converter = nil
        samples = []
        finishing = false
    }

    private func startAudio() throws {
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
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
        self.converter = converter
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let floats = Self.convert(buffer, with: converter, to: outputFormat)
            guard !floats.isEmpty else { return }
            Task { @MainActor in self?.append(floats) }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private nonisolated static func convert(
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
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, let data = converted.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(converted.frameLength)))
    }

    private func append(_ floats: [Float]) {
        samples.append(contentsOf: floats)
        let maxSamples = 30 * 16_000
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    private func transcribeLatest(isFinal: Bool) async {
        guard let whisperKit, !samples.isEmpty else {
            if isFinal { onFinal?("") }
            return
        }
        if transcriptionInFlight {
            transcriptionDirty = true
            return
        }
        transcriptionInFlight = true
        transcriptionDirty = false
        let audio = samples
        let prompt = "Jev Voice. Apps: " + vocabulary.prefix(60).joined(separator: ", ")
        let tokens = whisperKit.tokenizer.map {
            Array($0.encode(text: prompt).prefix(200))
        }
        let languageCode = Locale.current.language.languageCode?.identifier
        let language = languageCode.flatMap {
            Constants.languageCodes.contains($0) ? $0 : nil
        }
        let options = DecodingOptions(
            language: language,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: tokens
        )
        let result = await whisperKit.transcribe(audioArrays: [audio], decodeOptions: options)
        let text = (result.first ?? nil)?
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        if isFinal {
            onFinal?(text)
        } else if !text.isEmpty {
            onPartial?(text)
        }
        transcriptionInFlight = false
        if transcriptionDirty {
            await transcribeLatest(isFinal: finishing)
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
