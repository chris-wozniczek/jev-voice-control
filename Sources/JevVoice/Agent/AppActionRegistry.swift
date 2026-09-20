import Foundation

struct AppAction: Codable, Equatable {
    var app: String
    var bundleId: String?
    var name: String
    var phrases: [String]
    var steps: [AppActionStep]
}

enum AppActionStep: Codable, Equatable {
    case key(key: String, modifiers: [String])

    private enum CodingKeys: String, CodingKey {
        case kind, key, modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "key" else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported app action step"
            )
        }
        self = .key(
            key: try container.decode(String.self, forKey: .key),
            modifiers: try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .key(let key, let modifiers):
            try container.encode("key", forKey: .kind)
            try container.encode(key, forKey: .key)
            try container.encode(modifiers, forKey: .modifiers)
        }
    }
}

final class AppActionRegistry {
    static let shared = AppActionRegistry()

    private struct File: Codable {
        var actions: [AppAction]
    }

    private(set) var actions: [AppAction] = []

    static let userFileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("Jev Voice", isDirectory: true)
        .appendingPathComponent("app-actions.json")

    init() {
        reload()
    }

    init(bundledActions: [AppAction], userActions: [AppAction]) {
        actions = Self.merged(bundled: bundledActions, user: userActions)
    }

    func reload() {
        let bundled = Self.loadBundledActions()
        let user = Self.loadUserActions()
        actions = Self.merged(bundled: bundled, user: user)
    }

    func match(goal: String, appName: String?, bundleId: String?) -> AppAction? {
        let normalizedGoal = Self.normalize(goal)
        guard !normalizedGoal.isEmpty else { return nil }
        let specific = actions.filter { action in
            action.app != "*" && Self.matchesApp(
                action,
                appName: appName,
                bundleId: bundleId
            )
        }
        let wildcard = actions.filter { $0.app == "*" }
        func validAction(_ action: AppAction) -> Bool {
            guard let phrase = Self.matchedPhrase(in: normalizedGoal, action: action) else {
                return false
            }
            return Self.hasOnlyShortcutIntent(
                normalizedGoal,
                removing: phrase
            )
        }
        if let action = specific.filter(validAction).max(by: {
            Self.longestMatchingPhrase(in: normalizedGoal, action: $0)
                < Self.longestMatchingPhrase(in: normalizedGoal, action: $1)
        }) {
            return action
        }
        return wildcard.filter(validAction).max { lhs, rhs in
            Self.longestMatchingPhrase(in: normalizedGoal, action: lhs)
                < Self.longestMatchingPhrase(in: normalizedGoal, action: rhs)
        }
    }

    func ensureUserFileExists() {
        let url = Self.userFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(File(actions: []))
            try data.write(to: url, options: .atomic)
        } catch {
            Log.agent.error("could not create app-actions user file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadBundledActions() -> [AppAction] {
        guard let url = Bundle.module.url(
            forResource: "app-actions",
            withExtension: "json"
        ) else {
            return []
        }
        return decode(url: url)
    }

    private static func loadUserActions() -> [AppAction] {
        decode(url: userFileURL)
    }

    private static func decode(url: URL) -> [AppAction] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        return file.actions
    }

    private static func merged(
        bundled: [AppAction],
        user: [AppAction]
    ) -> [AppAction] {
        var merged = bundled
        for action in user {
            if let index = merged.firstIndex(where: {
                $0.app.caseInsensitiveCompare(action.app) == .orderedSame
                    && $0.name.caseInsensitiveCompare(action.name) == .orderedSame
            }) {
                merged[index] = action
            } else {
                merged.append(action)
            }
        }
        return merged
    }

    private static func matchesApp(
        _ action: AppAction,
        appName: String?,
        bundleId: String?
    ) -> Bool {
        if let actionBundleId = action.bundleId {
            return bundleId?.caseInsensitiveCompare(actionBundleId) == .orderedSame
        }
        guard let appName else { return false }
        return appName.caseInsensitiveCompare(action.app) == .orderedSame
    }

    private static func matchedPhrase(
        in goal: String,
        action: AppAction
    ) -> String? {
        action.phrases
            .map(Self.normalize)
            .filter { !$0.isEmpty && containsWordBounded(goal, phrase: $0) }
            .max { $0.count < $1.count }
    }

    private static func longestMatchingPhrase(
        in goal: String,
        action: AppAction
    ) -> Int {
        matchedPhrase(in: goal, action: action)?.count ?? 0
    }

    private static func hasOnlyShortcutIntent(
        _ goal: String,
        removing phrase: String
    ) -> Bool {
        var remaining = goal
        remaining = remaining.replacingOccurrences(
            of: " \(phrase) ",
            with: " ",
            options: .caseInsensitive
        )
        if remaining == goal, goal.hasPrefix(phrase + " ") {
            remaining = String(goal.dropFirst(phrase.count + 1))
        } else if remaining == goal, goal.hasSuffix(" " + phrase) {
            remaining = String(goal.dropLast(phrase.count + 1))
        } else if remaining == goal, goal == phrase {
            remaining = ""
        }
        let stopWords = Set([
            "a", "an", "the", "new", "please", "in", "open", "start", "create", "make",
        ])
        let extraWords = remaining.split(separator: " ").map(String.init).filter {
            !stopWords.contains($0)
        }
        return extraWords.count < 3
    }

    private static func containsWordBounded(_ goal: String, phrase: String) -> Bool {
        goal == phrase || goal.contains(" \(phrase) ") || goal.hasPrefix(phrase + " ")
            || goal.hasSuffix(" " + phrase)
    }

    static func normalize(_ text: String) -> String {
        var normalized = text.lowercased()
        if let range = normalized.range(of: #"^in [^,]+,\s*"#, options: .regularExpression) {
            normalized.removeSubrange(range)
        }
        normalized = normalized
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }
}
