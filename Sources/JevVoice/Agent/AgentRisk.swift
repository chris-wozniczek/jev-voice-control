enum AgentRisk {
    static let destructiveLabelWords = [
        "delete", "remove", "erase", "empty trash", "send", "submit", "pay", "buy",
        "purchase", "confirm", "uninstall", "shut down", "restart", "log out",
        "format", "replace all",
        "post", "publish", "tweet", "reply",
    ]
    static let destructiveGoalWords = [
        "delete", "remove", "erase", "empty trash", "send", "submit", "pay", "buy",
        "purchase", "confirm", "uninstall", "shut down", "restart", "log out",
        "format", "replace all",
    ]

    static func matchesDestructiveWord(_ text: String) -> Bool {
        matches(text, words: destructiveLabelWords)
    }

    static func matchesDestructiveGoal(_ text: String) -> Bool {
        matches(text, words: destructiveGoalWords)
    }

    private static func matches(_ text: String, words: [String]) -> Bool {
        let value = text.lowercased()
        return words.contains(where: value.contains)
    }
}
