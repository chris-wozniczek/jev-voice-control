import Foundation

public enum GoalWords {
    private static let stopWords: Set<String> = [
        "the", "a", "an", "to", "in", "on", "of", "and", "or", "for", "with",
        "my", "this", "that", "it", "please", "click", "open", "select",
        "choose", "pick", "change", "set", "new",
    ]

    public static func words(_ text: String) -> Set<String> {
        let tokens = text.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }
        var result = Set<String>()
        for token in tokens {
            let word = String(token)
            guard word.count >= 3, !stopWords.contains(word) else { continue }
            result.insert(word)
            if word.hasSuffix("s"), word.count > 3 {
                result.insert(String(word.dropLast()))
            }
        }
        return result
    }
}

public enum SubmitIntent {
    private static let verbs: Set<String> = [
        "send", "submit", "post", "enter", "run", "go",
    ]
    private static let optionalObjects: Set<String> = [
        "it", "the", "this", "that", "prompt", "message", "post",
        "reply", "form", "query", "command",
    ]

    public static func matches(goal: String) -> Bool {
        let normalized = goal.lowercased()
        if normalized.range(of: #"\bpress\s+enter\b"#, options: .regularExpression) != nil {
            return true
        }
        let words = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard let first = words.first, verbs.contains(first) else { return false }
        let tail = Array(words.dropFirst())
        guard tail.count <= 2 else { return false }
        if tail.count <= 1 {
            return tail.allSatisfy { optionalObjects.contains($0) }
        }
        let determiners: Set<String> = ["the", "this", "that"]
        let objects: Set<String> = [
            "prompt", "message", "post", "reply", "form", "query", "command",
        ]
        return determiners.contains(tail[0]) && objects.contains(tail[1])
    }
}
