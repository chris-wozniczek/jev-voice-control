import Foundation

public enum Action: String, CaseIterable, Codable {
    case openApp, closeApp, switchApp, minimizeApp, maximizeApp, fullscreenApp, restoreApp
    case hideApp, openURL, webSearch, dictate, uiTask, system, none

    public static let appTargeted: Set<Action> = [
        .openApp, .closeApp, .switchApp, .minimizeApp, .maximizeApp,
        .fullscreenApp, .restoreApp, .hideApp,
    ]

    public var description: String {
        switch self {
        case .openApp: return "Open or launch an application"
        case .closeApp: return "Close, quit, or exit an application"
        case .switchApp: return "Switch to, focus, or bring an application to the front"
        case .minimizeApp: return "Minimize an application's windows to the Dock"
        case .maximizeApp: return "Maximize or zoom an application's window to fill the screen"
        case .fullscreenApp: return "Put an application's window into full screen mode"
        case .restoreApp: return "Restore, un-minimize, or bring back an application's windows"
        case .hideApp: return "Hide an application"
        case .openURL: return "Open a specific website or URL in a browser"
        case .webSearch: return "Search the web for a query"
        case .dictate: return "Type or write text at the cursor"
        case .uiTask:
            return "Operate controls inside an application's own window: click or press a button, start or create something, choose a menu item, fill a field, open a link on a page — anything that requires looking at what the app shows"
        case .system: return "A system-level action not aimed at one app (volume, lock, sleep, screenshot, brightness, show desktop)"
        case .none: return "No actionable command"
        }
    }
}

public enum RiskTier: String, Codable {
    case safe, caution, destructive
}

public enum SystemAction: String, CaseIterable, Codable {
    case volumeSet, mute, unmute, volumeUp, volumeDown
    case lockScreen, sleep, screenshot
    case brightnessUp, brightnessDown, showDesktop
    case none

    public var description: String {
        switch self {
        case .volumeSet: return "Set volume to a specific level"
        case .mute: return "Mute audio"
        case .unmute: return "Unmute audio"
        case .volumeUp: return "Increase volume"
        case .volumeDown: return "Decrease volume"
        case .lockScreen: return "Lock the screen"
        case .sleep: return "Put the computer to sleep"
        case .screenshot: return "Take a screenshot"
        case .brightnessUp: return "Increase display brightness"
        case .brightnessDown: return "Decrease display brightness"
        case .showDesktop: return "Show the desktop"
        case .none: return "No system action"
        }
    }
}

public struct Decision {
    public let clause: String
    public var action: Action
    public var actionProbabilities: [String: Double]
    public var targetApp: String?
    public var spokenTarget: String?
    public var targetAppProbabilities: [String: Double]
    public var systemAction: SystemAction?
    public var url: String?
    public var query: String?
    public var text: String?
    public var percent: Int?
    public var destructive: Bool
    public var confidence: Double
    public var latencyMs: Double
    public var model: String

    public init(
        clause: String,
        action: Action,
        actionProbabilities: [String: Double] = [:],
        targetApp: String? = nil,
        spokenTarget: String? = nil,
        targetAppProbabilities: [String: Double] = [:],
        systemAction: SystemAction? = nil,
        url: String? = nil,
        query: String? = nil,
        text: String? = nil,
        percent: Int? = nil,
        destructive: Bool = false,
        confidence: Double = 0,
        latencyMs: Double = 0,
        model: String = ""
    ) {
        self.clause = clause
        self.action = action
        self.actionProbabilities = actionProbabilities
        self.targetApp = targetApp
        self.spokenTarget = spokenTarget
        self.targetAppProbabilities = targetAppProbabilities
        self.systemAction = systemAction
        self.url = url
        self.query = query
        self.text = text
        self.percent = percent
        self.destructive = destructive
        self.confidence = confidence
        self.latencyMs = latencyMs
        self.model = model
    }

    public var riskTier: RiskTier {
        if destructive {
            return .destructive
        }
        if action == .closeApp {
            return .caution
        }
        if action == .system,
           let systemAction,
           [.lockScreen, .sleep].contains(systemAction) {
            return .caution
        }
        return .safe
    }

    public var executionSummary: String {
        switch action {
        case .openApp: return "Open \(targetApp ?? "app")"
        case .closeApp: return "Close \(targetApp ?? "app")"
        case .switchApp: return "Switch to \(targetApp ?? "app")"
        case .minimizeApp: return "Minimize \(targetApp ?? "app")"
        case .maximizeApp: return "Maximize \(targetApp ?? "app")"
        case .fullscreenApp: return "Full screen \(targetApp ?? "app")"
        case .restoreApp: return "Restore \(targetApp ?? "app")"
        case .hideApp: return "Hide \(targetApp ?? "app")"
        case .openURL: return "Open \(url ?? "website")"
        case .webSearch: return "Search for \(query ?? "query")"
        case .dictate:
            let value = text ?? "text"
            return "Type “\(value)”"
        case .uiTask:
            return "In \(targetApp ?? "the current app"): \(clause)"
        case .system:
            switch systemAction ?? .none {
            case .volumeSet: return "Volume \(percent ?? 50)%"
            case .mute: return "Mute"
            case .unmute: return "Unmute"
            case .volumeUp: return "Volume up"
            case .volumeDown: return "Volume down"
            case .lockScreen: return "Lock the screen"
            case .sleep: return "Put the Mac to sleep"
            case .screenshot: return "Take a screenshot"
            case .brightnessUp: return "Brightness up"
            case .brightnessDown: return "Brightness down"
            case .showDesktop: return "Show the desktop"
            case .none: return "No action"
            }
        case .none: return "No action"
        }
    }
}
