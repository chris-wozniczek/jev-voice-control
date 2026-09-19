enum AgentRisk {
    static let destructiveWords = [
        "delete", "remove", "erase", "empty trash", "send", "submit", "pay", "buy",
        "purchase", "confirm", "uninstall", "shut down", "restart", "log out",
        "format", "replace all",
    ]

    static func matchesDestructiveWord(_ text: String) -> Bool {
        let value = text.lowercased()
        return destructiveWords.contains(where: value.contains)
    }
}
