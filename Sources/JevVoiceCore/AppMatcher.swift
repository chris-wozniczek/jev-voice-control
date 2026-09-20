import Foundation

public enum AppMatcher {
    public struct Match: Equatable {
        public let app: String
        /// 0.95 for an unambiguous full-name match, 0.8 for a token match, 0.5 when the best two candidates tie.
        public let confidence: Double
    }

    private static let stopWords: Set<String> = [
        "open", "close", "quit", "launch", "start", "kill", "exit", "switch", "to", "the",
        "app", "application", "please", "and", "then", "up", "my", "a", "an", "it",
        "minimize", "minimise", "hide", "focus", "show", "go", "bring", "front", "activate",
        "maximize", "maximise", "zoom", "fullscreen", "full", "screen", "restore", "window",
        "this", "that",
    ]

    public static let builtInAliases: [String: String] = [
        "chrome": "Google Chrome",
        "code": "Visual Studio Code",
        "vs code": "Visual Studio Code",
        "vscode": "Visual Studio Code",
        "cmux": "cmux",
        "c mux": "cmux",
        "see mux": "cmux",
        "sea mux": "cmux",
        "devin": "Devin",
        "devon": "Devin",
        "deven": "Devin",
        "settings": "System Settings",
        "system preferences": "System Settings",
        "preferences": "System Settings",
        "word": "Microsoft Word",
        "excel": "Microsoft Excel",
        "powerpoint": "Microsoft PowerPoint",
        "outlook": "Microsoft Outlook",
        "teams": "Microsoft Teams",
        "iterm": "iTerm",
        "i term": "iTerm",
        "edge": "Microsoft Edge",
        "brave": "Brave Browser",
        "chat gpt": "ChatGPT",
        "chatgpt": "ChatGPT",
        "claude": "Claude",
        "text edit": "TextEdit",
        "activity monitor": "Activity Monitor",
    ]

    private static let verbs: [(pattern: String, action: Action)] = [
        (#"^(maximi[sz]e|zoom|enlarge|make .* (big|bigger|large|larger)|full size)\b"#, .maximizeApp),
        (#"^(full ?screen|go full ?screen|enter full ?screen)\b"#, .fullscreenApp),
        (#"^(restore|un ?minimi[sz]e|bring back|unhide)\b"#, .restoreApp),
        (#"^(minimi[sz]e|shrink)\b"#, .minimizeApp),
        (#"^hide\b"#, .hideApp),
        (#"^(switch to|go to|focus( on)?|activate|bring up|show me|show)\b"#, .switchApp),
        (#"^(close|quit|exit|kill|terminate|shut( down)?)\b"#, .closeApp),
        (#"^(open|launch|start|run)\b"#, .openApp),
    ]

    /// Recognizes an app command from its leading verb, e.g. "minimize chrome" -> .minimizeApp.
    public static func verbAction(clause: String) -> Action? {
        let lowered = clause.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for verb in verbs where lowered.range(of: verb.pattern, options: .regularExpression) != nil {
            return verb.action
        }
        return nil
    }

    /// Finds the installed app most plausibly named in `clause`, e.g. "close chrome" -> "Google Chrome".
    public static func match(
        clause: String,
        installedApps: [String],
        aliases: [String: String] = [:]
    ) -> Match? {
        let clauseTokens = tokens(clause.lowercased())
        let words = clauseTokens.filter { !stopWords.contains($0) }
        guard !words.isEmpty else { return nil }

        for alias in aliases.keys.sorted(by: { tokens($0).count > tokens($1).count }) {
            let aliasTokens = tokens(alias.lowercased())
            guard !aliasTokens.isEmpty,
                  containsSequence(clauseTokens, aliasTokens),
                  let target = installedApps.first(where: {
                      $0.caseInsensitiveCompare(aliases[alias] ?? "") == .orderedSame
                  }) else {
                continue
            }
            return Match(app: target, confidence: 0.95)
        }

        var scored: [(app: String, score: Int, full: Bool)] = []
        for app in installedApps {
            let appTokens = tokens(app.lowercased())
            guard !appTokens.isEmpty else { continue }
            var score = 0
            let full = containsSequence(clauseTokens, appTokens)
            if full { score += 10 * appTokens.count }
            for word in words {
                if appTokens.contains(word) {
                    score += 4
                } else if word.count >= 4, appTokens.contains(where: { $0.hasPrefix(word) }) {
                    score += 2
                }
            }
            if score > 0 { scored.append((app, score, full)) }
        }
        scored.sort {
            $0.score != $1.score ? $0.score > $1.score : $0.app.count < $1.app.count
        }
        guard let best = scored.first else { return nil }
        if scored.count > 1, scored[1].score == best.score {
            return Match(app: best.app, confidence: 0.5)
        }
        return Match(app: best.app, confidence: best.full ? 0.95 : 0.8)
    }

    public static func spokenTarget(from clause: String) -> String? {
        let lowered = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = verbs.lazy.compactMap({
            lowered.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive])
        }).first else { return nil }
        let target = lowered[match.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.!?,;]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }

    public static func candidates(
        for spoken: String,
        installedApps: [String],
        aliases: [String: String] = [:],
        limit: Int = 3
    ) -> [String] {
        let query = normalize(spoken)
        guard !query.isEmpty else { return [] }
        var scored: [(name: String, score: Double)] = []
        for app in installedApps {
            let direct = similarity(query, normalize(app))
            var best = direct
            for (alias, target) in aliases where target.caseInsensitiveCompare(app) == .orderedSame {
                best = max(best, similarity(query, normalize(alias)))
            }
            if best >= 0.35 {
                scored.append((app, best))
            }
        }
        scored.sort {
            $0.score != $1.score
                ? $0.score > $1.score
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return Array(scored.prefix(limit).map(\.name))
    }

    public static func refersToFrontmostLocally(clause: String) -> Bool {
        let lowered = clause.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let verb = verbs.first(where: {
            lowered.range(of: $0.pattern, options: .regularExpression) != nil
        }) else { return false }
        guard let match = lowered.range(of: verb.pattern, options: .regularExpression) else {
            return false
        }
        let remainder = lowered[match.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.isEmpty { return true }
        let normalized = remainder.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let allowed = Set(["this", "that", "it", "the window", "current window", "this window"])
        return allowed.contains(normalized)
    }

    /// Words in `clause` that are neither command vocabulary nor part of the matched app's name/alias.
    public static func residualWords(
        clause: String,
        matchedApp: String,
        aliases: [String: String]
    ) -> [String] {
        let lowered = clause.lowercased()
        let ignored = stopWords.union([
            "desktop", "in", "on", "for", "with", "into", "now",
        ])
        let appTokens = tokens(matchedApp.lowercased())
        let aliasTokenSets = aliases
            .filter { $0.value.caseInsensitiveCompare(matchedApp) == .orderedSame }
            .map { tokens($0.key.lowercased()) }
        let verbRanges = verbs.compactMap {
            lowered.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive])
        }
        var residual: [String] = []
        lowered.enumerateSubstrings(
            in: lowered.startIndex..<lowered.endIndex,
            options: [.byWords]
        ) { substring, range, _, _ in
            guard let substring else { return }
            if verbRanges.contains(where: {
                $0.lowerBound < range.upperBound && range.lowerBound < $0.upperBound
            }) {
                return
            }
            let token = substring.lowercased()
            guard !ignored.contains(token),
                  !appTokens.contains(token),
                  !aliasTokenSets.contains(where: { $0.contains(token) }) else {
                return
            }
            let resemblesAppToken = appTokens.contains { appToken in
                (token.count >= 3 && appToken.hasPrefix(token))
                    || (appToken.count >= 3 && token.hasPrefix(appToken))
            }
            if !resemblesAppToken {
                residual.append(token)
            }
        }
        return residual
    }

    private static func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains {
            Array(haystack[$0..<($0 + needle.count)]) == needle
        }
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func normalize(_ value: String) -> String {
        tokens(value.lowercased()).joined()
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let lhsArray = Array(lhs)
        let rhsArray = Array(rhs)
        var previous = Array(0...rhsArray.count)
        for (row, lhsCharacter) in lhsArray.enumerated() {
            var current = [row + 1]
            for (column, rhsCharacter) in rhsArray.enumerated() {
                let cost = lhsCharacter == rhsCharacter ? 0 : 1
                current.append(min(
                    current[column] + 1,
                    previous[column + 1] + 1,
                    previous[column] + cost
                ))
            }
            previous = current
        }
        let distance = previous[rhsArray.count]
        return 1 - Double(distance) / Double(max(lhsArray.count, rhsArray.count))
    }
}
