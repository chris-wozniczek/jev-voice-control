import Foundation

public struct SafetyPolicy: Decodable {
    private enum CodingKeys: String, CodingKey {
        case blocked
        case confirm
        case confirmInBrowser
    }
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
    public let confirmInBrowser: [String]

    public init(blocked: [BlockedRule], confirm: [String], confirmInBrowser: [String] = []) {
        self.blocked = blocked
        self.confirm = confirm
        self.confirmInBrowser = confirmInBrowser
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blocked = try container.decode([BlockedRule].self, forKey: .blocked)
        confirm = try container.decode([String].self, forKey: .confirm)
        confirmInBrowser = try container.decodeIfPresent(
            [String].self,
            forKey: .confirmInBrowser
        ) ?? []
    }

    public static func load(from data: Data) throws -> SafetyPolicy {
        try JSONDecoder().decode(SafetyPolicy.self, from: data)
    }

    public func verdict(for transcript: String, inBrowser: Bool = false) -> Verdict? {
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
        let words = confirm + (inBrowser ? confirmInBrowser : [])
        for word in words {
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
            return .confirm(reason: "This will \(word) — confirm?")
        }
        return nil
    }
}
