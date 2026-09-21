import Foundation

public enum ClauseSplitter {
    static let commandVerbs: Set<String> = [
        "open", "launch", "close", "quit", "go", "type", "write", "search",
        "google", "set", "turn", "mute", "unmute", "lock", "sleep", "take",
        "switch", "show", "hide", "play", "pause", "next", "previous",
        "minimize", "minimise", "shrink", "focus", "activate", "bring", "run",
        "start", "exit", "kill", "terminate", "shut",
    ]

    public struct Boundary: Equatable {
        public let location: Int
        public let needsJudgment: Bool

        public init(location: Int, needsJudgment: Bool) {
            self.location = location
            self.needsJudgment = needsJudgment
        }
    }

    private struct Word {
        let range: NSRange
        let value: String
    }

    private enum BoundaryKind {
        case punctuation(Character)
        case conjunction
        case verb
    }

    private struct Candidate {
        let boundary: Boundary
        let kind: BoundaryKind
    }

    private static let conjunctionPattern = #"\b(and then|and also|then|and)\b"#
    private static let dictationVerbs: Set<String> = ["type", "write", "dictate", "say", "enter"]

    public static func candidateBoundaries(_ transcript: String) -> [Boundary] {
        let ns = transcript as NSString
        guard ns.length > 0 else { return [] }
        let words = words(in: transcript)
        var candidates: [Candidate] = []

        for index in 0..<ns.length {
            let character = ns.substring(with: NSRange(location: index, length: 1)).first!
            guard ",;.".contains(character) else { continue }
            let after = index + 1
            if character == ".", after < ns.length {
                let next = ns.substring(with: NSRange(location: after, length: 1)).first!
                if !next.isWhitespace { continue }
            }
            guard let word = firstWord(after: after, in: words, transcript: ns) else { continue }
            candidates.append(Candidate(
                boundary: Boundary(location: word.range.location, needsJudgment: false),
                kind: .punctuation(character)
            ))
        }

        if let regex = try? NSRegularExpression(pattern: conjunctionPattern, options: .caseInsensitive) {
            let fullRange = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: transcript, range: fullRange) {
                guard let word = firstWord(
                    after: match.range.location + match.range.length,
                    in: words,
                    transcript: ns
                ), commandVerbs.contains(word.value) else { continue }
                candidates.append(Candidate(
                    boundary: Boundary(location: word.range.location, needsJudgment: false),
                    kind: .conjunction
                ))
            }
        }

        for (index, word) in words.enumerated()
        where index > 0 && commandVerbs.contains(word.value) {
            guard !isSearchEngineWord(index: index, words: words) else { continue }
            guard !isPrecededByConjunction(index: index, words: words) else { continue }
            candidates.append(Candidate(
                boundary: Boundary(location: word.range.location, needsJudgment: true),
                kind: .verb
            ))
        }

        let sorted = candidates.sorted {
            if $0.boundary.location != $1.boundary.location {
                return $0.boundary.location < $1.boundary.location
            }
            return !$0.boundary.needsJudgment && $1.boundary.needsJudgment
        }
        var result: [Boundary] = []
        var seenLocations = Set<Int>()
        var dictationActive = words.first.map { dictationVerbs.contains($0.value) } ?? false

        for candidate in sorted {
            let location = candidate.boundary.location
            if seenLocations.contains(location) { continue }
            switch candidate.kind {
            case .punctuation:
                guard !dictationActive else { continue }
                result.append(candidate.boundary)
                seenLocations.insert(location)
                if let word = words.first(where: { $0.range.location == location }) {
                    dictationActive = dictationVerbs.contains(word.value)
                }
            case .conjunction, .verb:
                guard !dictationActive else { continue }
                result.append(candidate.boundary)
                seenLocations.insert(location)
                if let word = words.first(where: { $0.range.location == location }) {
                    dictationActive = dictationVerbs.contains(word.value)
                }
            }
        }
        return result
    }

    public static func split(_ transcript: String, boundaries: [Boundary]) -> [String] {
        split(transcript, boundaries: boundaries.map(\.location))
    }

    public static func split(_ transcript: String, boundaries: [Int]) -> [String] {
        let ns = transcript as NSString
        let locations = Array(Set(boundaries.filter { $0 > 0 && $0 < ns.length })).sorted()
        guard !locations.isEmpty else {
            let whole = cleanPiece(transcript)
            return whole.isEmpty ? [] : [whole]
        }

        var parts: [String] = []
        var last = 0
        for location in locations {
            let piece = ns.substring(with: NSRange(location: last, length: location - last))
            let cleaned = cleanPiece(piece)
            if !cleaned.isEmpty { parts.append(cleaned) }
            last = location
        }
        let tail = cleanPiece(ns.substring(from: last))
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }

    public static func stripTrailingEndWord(_ transcript: String) -> String {
        var result = transcript.replacingOccurrences(
            of: #"\s+(do it|execute|send it|over|that's it)[.!?,;]*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, ",;.".contains(last) {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func words(in transcript: String) -> [Word] {
        let ns = transcript as NSString
        var words: [Word] = []
        var index = 0
        while index < ns.length {
            let character = ns.substring(with: NSRange(location: index, length: 1)).first!
            guard character.isLetter || character.isNumber else {
                index += 1
                continue
            }
            let start = index
            index += 1
            while index < ns.length {
                let next = ns.substring(with: NSRange(location: index, length: 1)).first!
                guard next.isLetter || next.isNumber else { break }
                index += 1
            }
            words.append(Word(
                range: NSRange(location: start, length: index - start),
                value: ns.substring(with: NSRange(location: start, length: index - start)).lowercased()
            ))
        }
        return words
    }

    private static func firstWord(after location: Int, in words: [Word], transcript: NSString) -> Word? {
        words.first { word in
            guard word.range.location >= location else { return false }
            let between = transcript.substring(with: NSRange(
                location: location,
                length: word.range.location - location
            ))
            return between.allSatisfy { $0.isWhitespace }
        }
    }

    private static func isPrecededByConjunction(index: Int, words: [Word]) -> Bool {
        guard index > 0 else { return false }
        let previous = words[index - 1].value
        if previous == "and" || previous == "then" || previous == "also" {
            return true
        }
        return index > 1 && words[index - 2].value == "and" &&
            (previous == "then" || previous == "also")
    }

    private static func isSearchEngineWord(index: Int, words: [Word]) -> Bool {
        guard words[index].value == "google", index > 1 else { return false }
        guard ["in", "on", "with", "using"].contains(words[index - 1].value) else {
            return false
        }
        let prefixEnd = index - 1
        return words[..<prefixEnd].contains { $0.value == "search" || $0.value == "find" }
    }

    private static func cleanPiece(_ piece: String) -> String {
        var result = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        let conjunctionRegex = try? NSRegularExpression(
            pattern: #"^(and then|and also|then|and)\b"#,
            options: .caseInsensitive
        )
        while let conjunctionRegex,
              let match = conjunctionRegex.firstMatch(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length)
              ) {
            result = (result as NSString).substring(from: match.range.length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let first = result.first, ",;.".contains(first) {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let last = result.last, ",;.".contains(last) {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trailingConjunctionRegex = try? NSRegularExpression(
            pattern: #"\b(and then|and also|then|and)$"#,
            options: .caseInsensitive
        )
        while let trailingConjunctionRegex,
              let match = trailingConjunctionRegex.firstMatch(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length)
              ) {
            result = (result as NSString).substring(to: match.range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    public static func split(_ transcript: String) -> [String] {
        let pattern = #"\b(and then|and also|then|and)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return [transcript.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let ns = transcript as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: transcript, range: fullRange)

        var splitLocations: [(start: Int, resume: Int)] = []
        for match in matches {
            let after = match.range.location + match.range.length
            guard after < ns.length else { continue }
            var i = after
            while i < ns.length, !ns.substring(with: NSRange(location: i, length: 1)).first!.isLetter {
                i += 1
                if i >= ns.length { break }
            }
            guard i < ns.length else { continue }
            var j = i
            while j < ns.length {
                let ch = ns.substring(with: NSRange(location: j, length: 1)).first!
                if ch.isLetter || ch.isNumber { j += 1 } else { break }
            }
            let nextWord = ns.substring(with: NSRange(location: i, length: j - i)).lowercased()
            if commandVerbs.contains(nextWord) {
                splitLocations.append((start: match.range.location, resume: i))
            }
        }

        var parts: [String] = []
        var last = 0
        for loc in splitLocations {
            let piece = ns.substring(with: NSRange(location: last, length: loc.start - last))
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
            last = loc.resume
        }
        let tail = ns.substring(from: last).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts.isEmpty ? [transcript.trimmingCharacters(in: .whitespacesAndNewlines)] : parts
    }
}
