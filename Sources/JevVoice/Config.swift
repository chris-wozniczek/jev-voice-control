import Foundation
import Combine
import AVFoundation

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
	}
}
