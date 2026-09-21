import Foundation

public struct SafetyPolicy: Decodable {
    public enum Verdict: Equatable {
        case reject(reason: String)
        case confirm(reason: String)
    }

    public struct BlockedRule: Decodable, Equatable {
        public let pattern: String
        public let reason: String

        public init(pattern: String, reason: String) {
            self.pattern = pattern
            self.reason = reason
        }
    }
    public typealias Blocked = BlockedRule

    public let blocked: [BlockedRule]
    public let confirm: [String]

    public init(blocked: [BlockedRule], confirm: [String]) {
        self.blocked = blocked
        self.confirm = confirm
    }

    public static func load(from data: Data) throws -> SafetyPolicy {
        try JSONDecoder().decode(SafetyPolicy.self, from: data)
    }

    public func verdict(for transcript: String) -> Verdict? {
        for rule in blocked {
            guard let regex = try? NSRegularExpression(
                    pattern: rule.pattern,
                    options: [.caseInsensitive]
                  ),
                  regex.firstMatch(
                    in: transcript,
                    range: NSRange(location: 0, length: (transcript as NSString).length)
                  ) != nil else {
                continue
            }
            return .reject(reason: rule.reason)
        }
        for word in confirm {
            let escaped = NSRegularExpression.escapedPattern(for: word)
            guard let regex = try? NSRegularExpression(
                    pattern: "\\b\(escaped)\\b",
                    options: [.caseInsensitive]
                  ),
                  regex.firstMatch(
                    in: transcript,
                    range: NSRange(location: 0, length: (transcript as NSString).length)
                  ) != nil else {
                continue
            }
            return .confirm(reason: "\(word)— confirm?")
        }
        return nil
    }
}
