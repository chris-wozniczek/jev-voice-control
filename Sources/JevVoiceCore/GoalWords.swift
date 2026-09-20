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
