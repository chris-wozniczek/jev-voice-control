import Foundation
import Combine
import AVFoundation
import JevVoiceCore

enum ListeningMode: String, CaseIterable {
    case toggle, hold
}

enum SpeechEngineKind: String, CaseIterable {
    case apple, whisper
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

    @Published var cdpEnabled: Bool {
        didSet { UserDefaults.standard.set(cdpEnabled, forKey: "cdpEnabled") }
    }

    @Published var cdpPort: Int {
        didSet { UserDefaults.standard.set(cdpPort, forKey: "cdpPort") }
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

    @Published var plannerMode: PlannerMode {
        didSet { UserDefaults.standard.set(plannerMode.rawValue, forKey: "plannerMode") }
    }

    @Published var deepSeekThinking: DeepSeekThinking {
        didSet { UserDefaults.standard.set(deepSeekThinking.rawValue, forKey: "deepSeekThinking") }
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

    @Published var speechEngine: SpeechEngineKind {
        didSet { UserDefaults.standard.set(speechEngine.rawValue, forKey: "speechEngine") }
    }

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
        self.cdpEnabled = defaults.object(forKey: "cdpEnabled") as? Bool ?? true
        self.cdpPort = defaults.object(forKey: "cdpPort") as? Int ?? 9222
        self.generatorSource = GeneratorSource(
            rawValue: defaults.string(forKey: "generatorSource") ?? ""
        ) ?? .deepSeek
        self.omlxBaseURL = defaults.string(forKey: "omlxBaseURL") ?? "http://127.0.0.1:8000"
        self.omlxTextModel = defaults.string(forKey: "omlxTextModel") ?? ""
        self.previewGeneratedText = defaults.object(forKey: "previewGeneratedText") as? Bool ?? true
        self.plannerMode = PlannerMode(
            rawValue: defaults.string(forKey: "plannerMode") ?? ""
        ) ?? .jev
        self.deepSeekThinking = DeepSeekThinking(
            rawValue: defaults.string(forKey: "deepSeekThinking") ?? ""
        ) ?? .off
        self.listeningMode = ListeningMode(
            rawValue: defaults.string(forKey: "listeningMode") ?? ""
        ) ?? .toggle
        let timeout = defaults.object(forKey: "silenceTimeout") as? Double
            ?? HearingSettings.defaultSilenceTimeout
        self.silenceTimeout = HearingSettings.constrainedSilenceTimeout(timeout)
        self.speechEngine = SpeechEngineKind(
            rawValue: defaults.string(forKey: "speechEngine") ?? ""
        ) ?? .apple
        self.whisperModel = defaults.string(forKey: "whisperModel") ?? "openai_whisper-small"
    }
}
