@preconcurrency import AVFoundation
import Foundation
import Speech
import JevVoiceCore

#if compiler(>=6.2)
@available(macOS 26.0, *)
@MainActor
final class SpeechAnalyzerEngine: SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onListening: (() -> Void)?
    var onSilence: (() -> Void)?
    var onSpeechPause: ((String) -> Void)?
    var silenceTimeoutOverride: TimeInterval? {
        didSet { fallback?.silenceTimeoutOverride = silenceTimeoutOverride }
    }
    var onStatus: ((String?) -> Void)?
    var vocabulary: [String] = []

    static var streamingAvailable: Bool {
        if #available(macOS 26, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    private var audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var inputStream: AsyncStream<AnalyzerInput>?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var detector: SpeechDetector?
    private var setupTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var transcriberTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?
    private var fallback: AppleSpeechEngine?
    private var finalized = ""
    private var volatile = ""
    private var lastAudioAt = Date()
    private var lastSpeechAt = Date()
    private var speechStarted = false
    private var didSignalSilence = false
    private var didSignalPause = false
    private var didEmitFinal = false
    private var finishing = false
    private var generation = 0
    private var fallbackSilenceTask: Task<Void, Never>?

    static func preload() {
        guard Config.shared.speechEngine == .appleStreaming,
              streamingAvailable else { return }
        SpeechAnalyzerModelStore.shared.preload()
    }

    func start() throws {
        cancel()
        guard Self.streamingAvailable else {
            Log.speech.info("analyzer unavailable fallback=apple")
            let fallback = AppleSpeechEngine()
            fallback.onPartial = onPartial
            fallback.onFinal = onFinal
            fallback.onError = onError
            fallback.onListening = onListening
            fallback.onSilence = onSilence
            fallback.onSpeechPause = onSpeechPause
            fallback.silenceTimeoutOverride = silenceTimeoutOverride
            fallback.onStatus = onStatus
            fallback.vocabulary = vocabulary
            self.fallback = fallback
            try fallback.start()
            return
        }
        Log.speech.info("engine start name=SpeechAnalyzerEngine")
        generation += 1
        let currentGeneration = generation
        finalized = ""
        volatile = ""
        lastAudioAt = Date()
        lastSpeechAt = Date()
        speechStarted = false
        didSignalSilence = false
        didSignalPause = false
        silenceTimeoutOverride = nil
        didEmitFinal = false
        finishing = false
        let stream = AsyncStream<AnalyzerInput> { continuation in
            self.inputContinuation = continuation
        }
        inputStream = stream
        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.configureAndRun(
                    stream: stream,
                    generation: currentGeneration
                )
            } catch {
                guard self.generation == currentGeneration, !Task.isCancelled else { return }
                self.onStatus?(nil)
                self.onError?(error)
            }
        }
    }

    func finish() {
        if let fallback {
            fallback.finish()
            return
        }
        finishing = true
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        inputContinuation?.finish()
        inputContinuation = nil
        fallbackSilenceTask?.cancel()
        fallbackSilenceTask = nil
        guard let analyzer else {
            if !didEmitFinal {
                didEmitFinal = true
                onFinal?(Self.assembleFinal(finalized: finalized, volatile: volatile))
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await self.waitForTranscriber(timeout: .milliseconds(1_500))
                self.emitFinalIfNeeded()
            } catch {
                self.onError?(error)
            }
        }
    }

    func cancel() {
        generation += 1
        setupTask?.cancel()
        setupTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        transcriberTask?.cancel()
        transcriberTask = nil
        detectorTask?.cancel()
        detectorTask = nil
        fallbackSilenceTask?.cancel()
        fallbackSilenceTask = nil
        fallback?.cancel()
        fallback = nil
        inputContinuation?.finish()
        inputContinuation = nil
        inputStream = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        detector = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        converter = nil
        finishing = false
        finalized = ""
        volatile = ""
        didSignalSilence = false
        didEmitFinal = false
    }

    nonisolated static func assembleFinal(finalized: String, volatile: String) -> String {
        [finalized, volatile]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func configureAndRun(
        stream: AsyncStream<AnalyzerInput>,
        generation: Int
    ) async throws {
        let modules = try await Self.makeModules(vocabulary: vocabulary)
        await SpeechAnalyzerModelStore.shared.waitForPreload()
        try await Self.installAssets(modules: modules) { [weak self] status in
            self?.onStatus?(status)
        }
        guard self.generation == generation, !Task.isCancelled else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(vocabulary.prefix(200))
        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .processLifetime
            )
        )
        try await analyzer.setContext(context)
        let transcriber = modules.compactMap { $0 as? SpeechTranscriber }.first!
        let detector = modules.compactMap { $0 as? SpeechDetector }.first!
        let inputFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        let outputFormat = await transcriber.availableCompatibleAudioFormats.first
            ?? AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )!
        try await analyzer.prepareToAnalyze(in: outputFormat)
        try startAudio(inputFormat: inputFormat, outputFormat: outputFormat)
        guard self.generation == generation, !Task.isCancelled else { return }
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.detector = detector
        self.onStatus?(nil)
        onListening?()
        startFallbackSilenceTimer(generation: generation)
        transcriberTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.generation == generation else { return }
                    let text = String(result.text.characters)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.lastSpeechAt = Date()
                        self.didSignalPause = false
                        self.silenceTimeoutOverride = nil
                    }
                    if result.isFinal {
                        self.finalized = Self.assembleFinal(
                            finalized: self.finalized,
                            volatile: text
                        )
                        self.volatile = ""
                        self.onPartial?(self.finalized)
                        Log.speech.info(
                            "analyzer final=\(text, privacy: .public) elapsed=\(Date().timeIntervalSince(self.lastAudioAt), privacy: .public)"
                        )
                    } else {
                        self.volatile = text
                        self.onPartial?(Self.assembleFinal(
                            finalized: self.finalized,
                            volatile: self.volatile
                        ))
                        Log.speech.info(
                            "analyzer partial=\(text, privacy: .public) latency=\(Date().timeIntervalSince(self.lastAudioAt), privacy: .public)"
                        )
                    }
                }
                if let self, self.generation == generation, self.finishing {
                    self.emitFinalIfNeeded()
                }
            } catch {
                guard let self, self.generation == generation else { return }
                self.onError?(error)
            }
        }
        detectorTask = Task { @MainActor [weak self] in
            do {
                for try await result in detector.results {
                    guard let self, self.generation == generation else { return }
                    if result.speechDetected {
                        self.speechStarted = true
                        self.lastSpeechAt = Date()
                    }
                    if self.speechStarted,
                       Date().timeIntervalSince(self.lastSpeechAt) >= HearingSettings.pauseProbeDelay,
                       !self.didSignalPause,
                       !Self.assembleFinal(finalized: self.finalized, volatile: self.volatile)
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.didSignalPause = true
                        self.onSpeechPause?(Self.assembleFinal(
                            finalized: self.finalized,
                            volatile: self.volatile
                        ))
                    }
                    if self.speechStarted,
                       Date().timeIntervalSince(self.lastSpeechAt)
                            >= (self.silenceTimeoutOverride ?? Config.shared.silenceTimeout) {
                        self.signalSilence()
                    }
                }
            } catch {
                guard let self, self.generation == generation else { return }
                Log.speech.info(
                    "analyzer detector error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        analyzerTask = Task { @MainActor [weak self] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                guard let self, self.generation == generation else { return }
                self.onError?(error)
            }
        }
    }

    private func startAudio(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpeechEngineError.message("Unable to prepare microphone audio")
        }
        converter.primeMethod = .none
        self.converter = converter
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, _ in
            guard let converted = Self.convert(buffer, with: converter, to: outputFormat) else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastAudioAt = Date()
                let rms: Double
                if let channel = converted.floatChannelData?[0] {
                    rms = SpeechEnergy.rms(Array(UnsafeBufferPointer(
                        start: channel,
                        count: Int(converted.frameLength)
                    )))
                } else {
                    rms = 0
                }
                if SpeechEnergy.isVoiced(rms: rms, noiseFloor: 0.002) {
                    self.speechStarted = true
                    self.lastSpeechAt = Date()
                    self.didSignalPause = false
                    self.silenceTimeoutOverride = nil
                }
                self.inputContinuation?.yield(AnalyzerInput(buffer: converted))
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate))
        )
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && converted.frameLength > 0 ? converted : nil
    }

    private func signalSilence() {
        guard !didSignalSilence else { return }
        didSignalSilence = true
        onSilence?()
    }

    private func emitFinalIfNeeded() {
        guard !didEmitFinal else { return }
        didEmitFinal = true
        onFinal?(Self.assembleFinal(
            finalized: finalized,
            volatile: volatile
        ))
    }

    private func waitForTranscriber(timeout: Duration) async {
        guard let transcriberTask else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await transcriberTask.value
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func startFallbackSilenceTimer(generation: Int) {
        fallbackSilenceTask?.cancel()
        fallbackSilenceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.generation == generation else { return }
                guard self.speechStarted else { continue }
                if !self.didSignalPause,
                       !Self.assembleFinal(finalized: self.finalized, volatile: self.volatile)
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       Date().timeIntervalSince(self.lastSpeechAt) >= HearingSettings.pauseProbeDelay {
                        self.didSignalPause = true
                        self.onSpeechPause?(Self.assembleFinal(
                            finalized: self.finalized,
                            volatile: self.volatile
                        ))
                    }
                guard Date().timeIntervalSince(self.lastSpeechAt)
                        >= (self.silenceTimeoutOverride ?? Config.shared.silenceTimeout) else {
                    continue
                }
                self.signalSilence()
                return
            }
        }
    }

    static func makeModules(vocabulary: [String]) async throws -> [any SpeechModule] {
        let requested = Config.shared.speechLanguage
            .flatMap { Locale(identifier: $0) } ?? Locale.current
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
            ?? requested
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true
        )
        return [transcriber, detector]
    }

    static func installAssets(
        modules: [any SpeechModule],
        status: ((String?) -> Void)?
    ) async throws {
        let inventory = await AssetInventory.status(forModules: modules)
        guard inventory != .installed else { return }
        status?("Downloading speech model…")
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: modules
        ) else {
            throw SpeechEngineError.message("Speech model assets are unavailable")
        }
        try await request.downloadAndInstall()
        status?(nil)
    }
}
#else
@MainActor
final class SpeechAnalyzerEngine: SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onListening: (() -> Void)?
    var onSilence: (() -> Void)?
    var onSpeechPause: ((String) -> Void)?
    var silenceTimeoutOverride: TimeInterval?
    var onStatus: ((String?) -> Void)?
    var vocabulary: [String] = []

    static var streamingAvailable: Bool { false }
    static func preload() {}

    private var fallback: AppleSpeechEngine?

    func start() throws {
        Log.speech.info("analyzer not compiled fallback=apple")
        let fallback = AppleSpeechEngine()
        fallback.onPartial = onPartial
        fallback.onFinal = onFinal
        fallback.onError = onError
        fallback.onListening = onListening
        fallback.onSilence = onSilence
        fallback.onSpeechPause = onSpeechPause
        fallback.silenceTimeoutOverride = silenceTimeoutOverride
        fallback.onStatus = onStatus
        fallback.vocabulary = vocabulary
        self.fallback = fallback
        try fallback.start()
    }

    func finish() {
        fallback?.finish()
    }

    func cancel() {
        fallback?.cancel()
        fallback = nil
    }

    nonisolated static func assembleFinal(finalized: String, volatile: String) -> String {
        [finalized, volatile]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
#endif

#if compiler(>=6.2)
@available(macOS 26.0, *)
@MainActor
final class SpeechAnalyzerModelStore {
    static let shared = SpeechAnalyzerModelStore()
    private var preloadTask: Task<Void, Never>?

    func preload() {
        guard Config.shared.speechEngine == .appleStreaming,
              SpeechAnalyzerEngine.streamingAvailable,
              preloadTask == nil else { return }
        preloadTask = Task { @MainActor [weak self] in
            let started = Date()
            do {
                let modules = try await SpeechAnalyzerEngine.makeModules(vocabulary: [])
                try await SpeechAnalyzerEngine.installAssets(modules: modules, status: nil)
                let analyzer = SpeechAnalyzer(
                    modules: modules,
                    options: SpeechAnalyzer.Options(
                        priority: .userInitiated,
                        modelRetention: .processLifetime
                    )
                )
                let context = AnalysisContext()
                context.contextualStrings[.general] = Array(self?.vocabularyForPreload() ?? [])
                try await analyzer.setContext(context)
                try await analyzer.prepareToAnalyze(in: nil)
                Log.speech.info(
                    "analyzer preload ready elapsed=\(Date().timeIntervalSince(started), privacy: .public)"
                )
            } catch {
                Log.speech.info(
                    "analyzer preload failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
            self?.preloadTask = nil
        }
    }

    func waitForPreload() async {
        await preloadTask?.value
    }

    private func vocabularyForPreload() -> [String] {
        SpeechRecognizer.builtInVocabulary
    }
}
#else
@MainActor
final class SpeechAnalyzerModelStore {
    static let shared = SpeechAnalyzerModelStore()

    func preload() {}
    func waitForPreload() async {}
}
#endif
