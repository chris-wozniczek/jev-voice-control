import Foundation
import Combine
import AVFoundation
import JevVoiceCore
import Speech

enum ListeningMode: String, CaseIterable {
    case toggle, hold
}

enum SpeechEngineKind: String, CaseIterable {
    case apple, whisper
    case appleStreaming

    static func defaultKind(streamingAvailable: Bool) -> SpeechEngineKind {
        streamingAvailable ? .appleStreaming : .apple
    }

    static let streamingCompiledIn: Bool = {
#if compiler(>=6.2)
        true
#else
        false
#endif
    }()

    static var streamingAvailable: Bool {
#if compiler(>=6.2)
        if #available(macOS 26, *) {
            return SpeechTranscriber.isAvailable
        }
#endif
        return false
    }
}

enum DeepSeekThinking: String, CaseIterable {
    case off, low, high
}

enum PlannerMode: String, CaseIterable {
    case jev, deepSeek
}

enum GeneratorSource: String, CaseIterable {
    case deepSeek, omlx
}

final class Config: ObservableObject {
    static let shared = Config()

    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "typesafeAPIKey") }
    }

    @Published var speakReplies: Bool {
        didSet { UserDefaults.standard.set(speakReplies, forKey: "speakReplies") }
    }

    @Published var voiceIdentifier: String? {
        didSet {
            if let voiceIdentifier {
                UserDefaults.standard.set(voiceIdentifier, forKey: "voiceIdentifier")
            } else {
                UserDefaults.standard.removeObject(forKey: "voiceIdentifier")
            }
        }
    }

    @Published var speechRate: Float {
        didSet { UserDefaults.standard.set(speechRate, forKey: "speechRate") }
    }

    @Published var alwaysConfirm: Bool {
        didSet { UserDefaults.standard.set(alwaysConfirm, forKey: "alwaysConfirm") }
    }

	@Published var appAliases: [String: String] {
		didSet { UserDefaults.standard.set(appAliases, forKey: "appAliases") }
	}

	@Published var deepSeekAPIKey: String {
		didSet { UserDefaults.standard.set(deepSeekAPIKey, forKey: "deepSeekAPIKey") }
	}

    @Published var computerUseEnabled: Bool {
        didSet { UserDefaults.standard.set(computerUseEnabled, forKey: "computerUseEnabled") }
    }

    @Published var appActionsEnabled: Bool {
        didSet { UserDefaults.standard.set(appActionsEnabled, forKey: "appActionsEnabled") }
    }

    @Published var nativeAXEnabled: Bool {
        didSet { UserDefaults.standard.set(nativeAXEnabled, forKey: "nativeAXEnabled") }
    }

    @Published var ocrFallbackEnabled: Bool {
        didSet { UserDefaults.standard.set(ocrFallbackEnabled, forKey: "ocrFallbackEnabled") }
    }

    @Published var cdpEnabled: Bool {
        didSet { UserDefaults.standard.set(cdpEnabled, forKey: "cdpEnabled") }
    }

    @Published var cdpPort: Int {
        didSet { UserDefaults.standard.set(cdpPort, forKey: "cdpPort") }
    }

    @Published var defaultBrowser: String {
        didSet { UserDefaults.standard.set(defaultBrowser, forKey: "defaultBrowser") }
    }

    @Published var generatorSource: GeneratorSource {
        didSet { UserDefaults.standard.set(generatorSource.rawValue, forKey: "generatorSource") }
    }

    @Published var omlxBaseURL: String {
        didSet { UserDefaults.standard.set(omlxBaseURL, forKey: "omlxBaseURL") }
    }

    @Published var omlxTextModel: String {
        didSet { UserDefaults.standard.set(omlxTextModel, forKey: "omlxTextModel") }
    }

    @Published var previewGeneratedText: Bool {
        didSet { UserDefaults.standard.set(previewGeneratedText, forKey: "previewGeneratedText") }
    }

    @Published var learnedToolsEnabled: Bool {
        didSet { UserDefaults.standard.set(learnedToolsEnabled, forKey: "learnedToolsEnabled") }
    }

    @Published var plannerMode: PlannerMode {
        didSet { UserDefaults.standard.set(plannerMode.rawValue, forKey: "plannerMode") }
    }

    @Published var deepSeekThinking: DeepSeekThinking {
        didSet { UserDefaults.standard.set(deepSeekThinking.rawValue, forKey: "deepSeekThinking") }
    }

    @Published var fallbackMaxSteps: Int {
        didSet { UserDefaults.standard.set(fallbackMaxSteps, forKey: "fallbackMaxSteps") }
    }

    @Published var fallbackMaxSeconds: Double {
        didSet { UserDefaults.standard.set(fallbackMaxSeconds, forKey: "fallbackMaxSeconds") }
    }

    @Published var listeningMode: ListeningMode {
        didSet { UserDefaults.standard.set(listeningMode.rawValue, forKey: "listeningMode") }
    }

    @Published var silenceTimeout: Double {
        didSet {
            let constrained = HearingSettings.constrainedSilenceTimeout(silenceTimeout)
            if constrained != silenceTimeout {
                silenceTimeout = constrained
            } else {
                UserDefaults.standard.set(silenceTimeout, forKey: "silenceTimeout")
            }
        }
    }

    @Published var endOfTurnJudgeEnabled: Bool {
        didSet { UserDefaults.standard.set(endOfTurnJudgeEnabled, forKey: "endOfTurnJudgeEnabled") }
    }

    @Published var speechEngine: SpeechEngineKind {
        didSet { UserDefaults.standard.set(speechEngine.rawValue, forKey: "speechEngine") }
    }

    @Published var speechLanguage: String? {
        didSet {
            if let speechLanguage, !speechLanguage.isEmpty {
                UserDefaults.standard.set(speechLanguage, forKey: "speechLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "speechLanguage")
            }
        }
    }

    @Published var customVocabulary: [String] {
        didSet { UserDefaults.standard.set(customVocabulary, forKey: "customVocabulary") }
    }

    @Published private(set) var safetyPolicy: SafetyPolicy?
    @Published private(set) var safetyPolicyPath: String?

    @Published var whisperModel: String {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisperModel") }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.apiKey = defaults.string(forKey: "typesafeAPIKey")
            ?? ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]
            ?? ""
        self.speakReplies = defaults.object(forKey: "speakReplies") as? Bool ?? true
        self.voiceIdentifier = defaults.string(forKey: "voiceIdentifier")
        self.speechRate = defaults.object(forKey: "speechRate") == nil
            ? AVSpeechUtteranceDefaultSpeechRate
            : defaults.float(forKey: "speechRate")
        if let stored = defaults.object(forKey: "alwaysConfirm") as? Bool {
            self.alwaysConfirm = stored
        } else {
            self.alwaysConfirm = (defaults.object(forKey: "autoExecute") as? Bool) == false
        }
        self.appAliases = defaults.dictionary(forKey: "appAliases") as? [String: String] ?? [:]
        self.deepSeekAPIKey = defaults.string(forKey: "deepSeekAPIKey")
            ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
            ?? ""
        self.computerUseEnabled = defaults.object(forKey: "computerUseEnabled") as? Bool ?? true
        self.appActionsEnabled = defaults.object(forKey: "appActionsEnabled") as? Bool ?? true
        self.nativeAXEnabled = defaults.object(forKey: "nativeAXEnabled") as? Bool ?? true
        self.ocrFallbackEnabled = defaults.object(forKey: "ocrFallbackEnabled") as? Bool ?? true
        self.cdpEnabled = defaults.object(forKey: "cdpEnabled") as? Bool ?? true
        self.cdpPort = defaults.object(forKey: "cdpPort") as? Int ?? 9222
        self.defaultBrowser = defaults.string(forKey: "defaultBrowser") ?? "Google Chrome"
        self.generatorSource = GeneratorSource(
            rawValue: defaults.string(forKey: "generatorSource") ?? ""
        ) ?? .deepSeek
        self.omlxBaseURL = defaults.string(forKey: "omlxBaseURL") ?? "http://127.0.0.1:8000"
        self.omlxTextModel = defaults.string(forKey: "omlxTextModel") ?? ""
        self.previewGeneratedText = defaults.object(forKey: "previewGeneratedText") as? Bool ?? true
        self.learnedToolsEnabled = defaults.object(forKey: "learnedToolsEnabled") as? Bool ?? true
        self.plannerMode = PlannerMode(
            rawValue: defaults.string(forKey: "plannerMode") ?? ""
        ) ?? .jev
        self.deepSeekThinking = DeepSeekThinking(
            rawValue: defaults.string(forKey: "deepSeekThinking") ?? ""
        ) ?? .off
        self.fallbackMaxSteps = defaults.object(forKey: "fallbackMaxSteps") as? Int ?? 6
        self.fallbackMaxSeconds = defaults.object(forKey: "fallbackMaxSeconds") as? Double ?? 30
        self.listeningMode = ListeningMode(
            rawValue: defaults.string(forKey: "listeningMode") ?? ""
        ) ?? .toggle
        let timeout = defaults.object(forKey: "silenceTimeout") as? Double
            ?? HearingSettings.defaultSilenceTimeout
        self.silenceTimeout = HearingSettings.constrainedSilenceTimeout(timeout)
        self.endOfTurnJudgeEnabled = defaults.object(forKey: "endOfTurnJudgeEnabled") as? Bool ?? true
        if let storedSpeechEngine = defaults.string(forKey: "speechEngine"),
           let speechEngine = SpeechEngineKind(rawValue: storedSpeechEngine) {
            self.speechEngine = speechEngine
        } else {
            if SpeechEngineKind.streamingAvailable {
                self.speechEngine = .defaultKind(streamingAvailable: true)
            } else {
                self.speechEngine = .defaultKind(streamingAvailable: false)
            }
        }
        self.speechLanguage = defaults.string(forKey: "speechLanguage")
        self.customVocabulary = defaults.stringArray(forKey: "customVocabulary")
            ?? ["x.com", "Grok", "Devin", "cmux", "ChatGPT", "Claude", "Gemini", "GitHub"]
        self.whisperModel = defaults.string(forKey: "whisperModel") ?? "openai_whisper-small"
        let loadedPolicy = Self.loadSafetyPolicy()
        self.safetyPolicy = loadedPolicy.policy
        self.safetyPolicyPath = loadedPolicy.path
    }

    private static func loadSafetyPolicy() -> (policy: SafetyPolicy?, path: String?) {
        let userURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
            .appendingPathComponent("Jev Voice", isDirectory: true)
            .appendingPathComponent("policy.json")
        if let data = try? Data(contentsOf: userURL) {
            if let policy = try? SafetyPolicy.load(from: data) {
                Log.command.info("safety policy loaded path=\(userURL.path, privacy: .public)")
                return (policy, userURL.path)
            }
            Log.command.info("safety policy invalid path=\(userURL.path, privacy: .public)")
        }

        var bundles = [Bundle.main]
        if let url = Bundle.main.url(
            forResource: "JevVoice_JevVoice",
            withExtension: "bundle"
        ), let bundle = Bundle(url: url) {
            bundles.append(bundle)
        }
#if DEBUG
        bundles.append(Bundle.module)
#endif
        for bundle in bundles {
            guard let url = bundle.url(forResource: "policy", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let policy = try? SafetyPolicy.load(from: data) else {
                continue
            }
            Log.command.info("safety policy loaded path=\(url.path, privacy: .public)")
            return (policy, url.path)
        }
        Log.command.info("safety policy unavailable")
        return (nil, nil)
    }
}
