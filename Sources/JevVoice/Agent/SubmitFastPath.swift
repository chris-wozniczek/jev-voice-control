import Foundation

enum SubmitFastPath {
    struct Attempt {
        let logKey: String
        let key: String
        let modifiers: [String]
    }

    static let attempts = [
        Attempt(logKey: "cmd-return", key: "return", modifiers: ["command"]),
        Attempt(logKey: "return", key: "return", modifiers: []),
    ]
}
