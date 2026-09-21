enum AgentRisk {
    static let destructiveLabelWords = [
        "delete", "remove", "erase", "empty trash", "pay", "buy",
        "purchase", "confirm", "uninstall", "shut down", "restart", "log out",
        "format", "replace all",
    ]
    static let destructiveGoalWords = [
        "delete", "remove", "erase", "empty trash", "pay", "buy",
        "purchase", "confirm", "uninstall", "shut down", "restart", "log out",
        "format", "replace all",
    ]
    static let browserLabelWords = ["send", "submit", "post", "publish", "tweet", "reply"]
    static let browserGoalWords = browserLabelWords

    static func matchesDestructiveWord(_ text: String) -> Bool {
        matches(text, words: destructiveLabelWords)
    }

    static func matchesDestructiveGoal(_ text: String) -> Bool {
        matches(text, words: destructiveGoalWords)
    }

    static func matchesBrowserRisk(_ text: String) -> Bool {
        matches(text, words: browserLabelWords)
    }

    static func matchesBrowserGoal(_ text: String) -> Bool {
        matches(text, words: browserGoalWords)
    }

    private static func matches(_ text: String, words: [String]) -> Bool {
        let value = text.lowercased()
        return words.contains(where: value.contains)
    }
}
