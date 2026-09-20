import Foundation

public enum TranscriptNormalizer {
    public static func normalize(_ transcript: String) -> String {
        var result = transcript
        result = splitGluedFillerHost(result)
        result = splitWholeGluedHost(result)
        result = dropWebsiteFiller(result)
        result = splitSentenceGluedHost(result)
        return result
    }

    private static func splitGluedFillerHost(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![a-z0-9-])(website|site)([a-z0-9-]+\.[a-z]{2,}(?:/\S*)?)"#,
            options: .caseInsensitive
        ) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1 $2"
        )
    }

    private static func splitWholeGluedHost(_ text: String) -> String {
        if let regex = try? NSRegularExpression(
            pattern: #"^(open|goto|visit|launch)(website|site)([a-z0-9-]+\.[a-z]{2,}(?:/\S*)?)$"#,
            options: .caseInsensitive
        ) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            if let match = regex.firstMatch(in: text, range: range),
               let verbRange = Range(match.range(at: 1), in: text),
               let hostRange = Range(match.range(at: 3), in: text) {
                let verb = String(text[verbRange])
                let normalizedVerb = verb.caseInsensitiveCompare("goto") == .orderedSame
                    ? "go to"
                    : verb
                return "\(normalizedVerb) website \(text[hostRange])"
            }
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"^(open|goto|visit|launch|website|site)([a-z0-9-]+\.[a-z]{2,}(?:/\S*)?)$"#,
            options: .caseInsensitive
        ) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, range: range),
              let prefixRange = Range(match.range(at: 1), in: text),
              let hostRange = Range(match.range(at: 2), in: text) else {
            return text
        }
        let prefix = String(text[prefixRange])
        let host = String(text[hostRange])
        let verb = prefix.caseInsensitiveCompare("goto") == .orderedSame ? "go to" : prefix
        return "\(verb) \(host)"
    }

    private static func dropWebsiteFiller(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"^(open|go to|visit)\s+(the website|website|site|page)\s+(\S+\.[a-z]{2,}(?:/\S*)?)$"#,
            options: .caseInsensitive
        ) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, range: range),
              let verbRange = Range(match.range(at: 1), in: text),
              let hostRange = Range(match.range(at: 3), in: text) else {
            return text
        }
        return "\(text[verbRange]) \(text[hostRange])"
    }

    private static func splitSentenceGluedHost(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(open|goto|visit|launch)([a-z0-9-]+\.[a-z]{2,}(?:/\S*)?)\b"#,
            options: .caseInsensitive
        ) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        var result = text
        for match in matches.reversed() {
            guard let prefixRange = Range(match.range(at: 1), in: result),
                  let hostRange = Range(match.range(at: 2), in: result) else {
                continue
            }
            let prefix = String(result[prefixRange])
            let host = String(result[hostRange])
            let before = String(result[..<prefixRange.lowerBound]).lowercased()
            if before.hasSuffix("open ") || before.hasSuffix("go to ") ||
                before.hasSuffix("visit ") || before.hasSuffix("launch ") {
                continue
            }
            let verb = prefix.caseInsensitiveCompare("goto") == .orderedSame ? "go to" : prefix
            result.replaceSubrange(prefixRange.lowerBound..<hostRange.upperBound, with: "\(verb) \(host)")
        }
        return result
    }
}
