import Foundation

public enum SlotExtractor {
    private static let urlPattern = #"[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|org|net|io|ai|dev|co|app|pl|me|gg|tv|edu|gov|uk|de)(/\S*)?"#

    public static func url(from clause: String) -> String? {
        var s = " " + clause.lowercased() + " "
        s = s.replacingOccurrences(of: "w w w", with: "www")
        s = s.replacingOccurrences(of: " dot ", with: ".")
        s = s.replacingOccurrences(of: " slash ", with: "/")
        s = s.replacingOccurrences(of: " colon ", with: ":")
        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return nil }
        let range = NSRange(location: 0, length: (s as NSString).length)
        guard let match = regex.firstMatch(in: s, range: range) else { return nil }
        var host = (s as NSString).substring(with: match.range)
        while host.hasSuffix(".") || host.hasSuffix(",") { host = String(host.dropLast()) }
        return "https://" + host
    }

    public static func searchQuery(from clause: String) -> String? {
        let lowered = clause.lowercased()
        let triggers = ["search for", "look up", "search", "google", "find"]
        var best: Range<String.Index>?
        for trigger in triggers {
            if let range = lowered.range(of: #"\b"# + trigger + #"\b"#, options: .regularExpression) {
                if best == nil || range.lowerBound < best!.lowerBound { best = range }
            }
        }
        guard let range = best else { return nil }
        var query = String(clause[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trailingSearchEngineMatch(in: query) {
            query.removeSubrange(match.fullRange)
            query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return query.isEmpty ? nil : query
    }

    public static func fallbackSearchQuery(from clause: String) -> String? {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return nil }
        let first = words.first.map(String.init)?.lowercased() ?? ""
        if ["who", "what", "when", "where", "how"].contains(first) {
            return trimmed
        }
        let triggers = [
            "check out", "tell me", "find out", "search for", "look up",
            "check", "google", "search", "find", "look at",
        ]
        let lowered = trimmed.lowercased()
        guard let trigger = triggers.sorted(by: { $0.count > $1.count }).first(where: {
            lowered.range(of: "^" + NSRegularExpression.escapedPattern(for: $0) + #"\b"#,
                          options: .regularExpression) != nil
        }) else {
            return nil
        }
        var remainder = String(trimmed.dropFirst(trigger.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let articles = ["the", "a", "an"]
        if let article = articles.first(where: {
            remainder.range(
                of: "^" + $0 + #"\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }) {
            remainder = String(remainder.dropFirst(article.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return remainder.split(whereSeparator: \.isWhitespace).count >= 2 ? remainder : nil
    }

    public static func searchBrowser(from clause: String) -> String? {
        guard let match = trailingSearchEngineMatch(in: clause) else { return nil }
        let phrase = String(clause[match.appRange]).lowercased()
        switch phrase {
        case "chrome", "google chrome":
            return "Google Chrome"
        case "safari":
            return "Safari"
        case "firefox":
            return "Firefox"
        case "arc":
            return "Arc"
        case "brave":
            return "Brave Browser"
        case "edge":
            return "Microsoft Edge"
        default:
            return nil
        }
    }

    public static func dictationText(from clause: String) -> String? {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["type in", "type out", "type", "write", "dictate", "say", "enter"]
            .sorted { $0.count > $1.count }
        guard let prefix = prefixes.first(where: { candidate in
            guard let range = trimmed.range(of: candidate, options: .caseInsensitive),
                  range.lowerBound == trimmed.startIndex else {
                return false
            }
            guard range.upperBound < trimmed.endIndex else { return true }
            let next = trimmed[range.upperBound]
            return next.isWhitespace || ":,-—".contains(next)
        }), let range = trimmed.range(of: prefix, options: .caseInsensitive) else {
            return nil
        }
        var text = String(trimmed[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, ":,-—".contains(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fillerWords = ["prompt", "message", "text", "following"]
        let fillerPrefixes = (
            fillerWords
                + ["the", "a", "this"].flatMap { article in
                    fillerWords.map { "\(article) \($0)" }
                }
        ).sorted { $0.count > $1.count }
        if let filler = fillerPrefixes.first(where: { candidate in
            guard let match = text.range(of: candidate, options: .caseInsensitive),
                  match.lowerBound == text.startIndex else {
                return false
            }
            guard match.upperBound < text.endIndex else { return true }
            let next = text[match.upperBound]
            return next.isWhitespace || ":,-—".contains(next)
        }), let fillerRange = text.range(of: filler, options: .caseInsensitive) {
            text = String(text[fillerRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = text.first, ":,-—".contains(first) {
                text.removeFirst()
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public static func composeRequest(from clause: String) -> String? {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"[“”"]|(?:^|\s)'[^']*(?:'|$)"#,
                        options: [.regularExpression, .caseInsensitive]) == nil,
              trimmed.range(of: #"\b(?:saying|that says)\b"#,
                            options: [.regularExpression, .caseInsensitive]) == nil else {
            return nil
        }
        let postWords = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if postWords.count >= 5,
           postWords[0].caseInsensitiveCompare("post") == .orderedSame,
           postWords[1].caseInsensitiveCompare("on") == .orderedSame,
           let aboutIndex = postWords.firstIndex(where: {
               $0.caseInsensitiveCompare("about") == .orderedSame
           }) {
            let postBrief = postWords[aboutIndex...].joined(separator: " ")
            return postBrief.isEmpty ? nil : postBrief
        }
        if let postRange = trimmed.range(
            of: #"^\s*post\s+(?:about|on)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let postBrief = trimmed[postRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return postBrief.isEmpty ? nil : "about \(postBrief)"
        }
        guard let match = trimmed.range(
            of: #"^\s*(?:write|type|compose|draft|reply\s+with|answer\s+with)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        let brief = trimmed[match.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return nil }
        let hasArticleAndNoun = brief.range(
            of: #"\b(?:a|an)\b\s+.*\b(?:post|tweet|thread|comment|caption|announcement|status\s+update|reply|bio|note|message|email|apology|apologising|apologizing|summary|paragraph|text|thank[- ]you|response)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let hasOwnWordsCue = brief.range(
            of: #"\b(?:in my own words|something like|apologising|apologizing)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if hasArticleAndNoun || hasOwnWordsCue {
            return brief
        }
        return nil
    }

    public static func typedText(from clause: String) -> String? {
        if let match = clause.range(of: #""([^"]+)"|'([^']+)'"#, options: .regularExpression) {
            let quoted = String(clause[match])
            return String(quoted.dropFirst().dropLast())
        }
        let pattern = #"\b(saying|that says|asking|ask it to|with the text|enter)\b"#
        if let range = clause.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            let text = clause[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return dictationText(from: clause)
    }

    public static func numberPercent(from clause: String) -> Int? {
        let lowered = clause.lowercased()
        if let regex = try? NSRegularExpression(pattern: #"\b(\d{1,3})\b"#),
           let match = regex.firstMatch(in: lowered, range: NSRange(location: 0, length: (lowered as NSString).length)),
           let value = Int((lowered as NSString).substring(with: match.range(at: 1))),
           (0...100).contains(value) {
            return value
        }
        if lowered.range(of: #"\b(max|maximum|full)\b"#, options: .regularExpression) != nil { return 100 }
        if lowered.range(of: #"\bhalf\b"#, options: .regularExpression) != nil { return 50 }
        if lowered.range(of: #"\boff\b"#, options: .regularExpression) != nil { return 0 }
        return nil
    }

    private struct SearchEngineMatch {
        let fullRange: Range<String.Index>
        let appRange: Range<String.Index>
    }

    private static func trailingSearchEngineMatch(in text: String) -> SearchEngineMatch? {
        let pattern = #"\s+(in|on|with|using)\s+(google chrome|google|chrome|safari|firefox|arc|brave|edge|bing|duckduckgo)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: fullRange),
              let full = Range(match.range, in: text),
              let app = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return SearchEngineMatch(fullRange: full, appRange: app)
    }
}
