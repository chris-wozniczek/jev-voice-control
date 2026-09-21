import Foundation

public struct LearnedToolArgument: Codable, Equatable {
    public let name: String
    public let type: String
    public let values: [String]?
    public let description: String

    public init(
        name: String,
        type: String,
        values: [String]? = nil,
        description: String = ""
    ) {
        self.name = name
        self.type = type
        self.values = values
        self.description = description
    }
}

public struct LearnedTool: Codable, Equatable, Identifiable {
    public let name: String
    public let description: String
    public let language: String
    public let arguments: [LearnedToolArgument]
    public let script: String
    public let spokenResult: String
    public let mutates: Bool
    public let verifyScript: String?
    public let utteranceExamples: [String]

    public var id: String { name }

    public init(
        name: String,
        description: String,
        language: String,
        arguments: [LearnedToolArgument],
        script: String,
        spokenResult: String,
        mutates: Bool,
        verifyScript: String? = nil,
        utteranceExamples: [String] = []
    ) {
        self.name = name
        self.description = description
        self.language = language
        self.arguments = arguments
        self.script = script
        self.spokenResult = spokenResult
        self.mutates = mutates
        self.verifyScript = verifyScript
        self.utteranceExamples = utteranceExamples
    }

    public static func render(script: String, args: [String: String]) -> String {
        var rendered = script
        for (name, value) in args {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            rendered = rendered.replacingOccurrences(
                of: "{{\(name)}}",
                with: "\"\(escaped)\""
            )
            rendered = rendered.replacingOccurrences(
                of: "{{\(name) == on}}",
                with: value.caseInsensitiveCompare("on") == .orderedSame ? "true" : "false"
            )
            rendered = rendered.replacingOccurrences(
                of: "{{\(name) == off}}",
                with: value.caseInsensitiveCompare("off") == .orderedSame ? "true" : "false"
            )
            rendered = rendered.replacingOccurrences(
                of: "{{\(name) == true}}",
                with: value.caseInsensitiveCompare("true") == .orderedSame ? "true" : "false"
            )
            rendered = rendered.replacingOccurrences(
                of: "{{\(name) == false}}",
                with: value.caseInsensitiveCompare("false") == .orderedSame ? "true" : "false"
            )
            if Double(value) != nil || value == "true" || value == "false" {
                rendered = rendered.replacingOccurrences(of: "\"\(escaped)\"", with: value)
            }
        }
        let pattern = #"\{\{([A-Za-z0-9_]+)\s*==\s*([^}]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return rendered
        }
        let range = NSRange(location: 0, length: (rendered as NSString).length)
        let matches = regex.matches(in: rendered, range: range).reversed()
        for match in matches {
            guard match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: rendered),
                  let expectedRange = Range(match.range(at: 2), in: rendered),
                  let value = args[String(rendered[nameRange])] else {
                continue
            }
            let expected = String(rendered[expectedRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = value.caseInsensitiveCompare(expected) == .orderedSame
                ? "true"
                : "false"
            guard let fullRange = Range(match.range, in: rendered) else { continue }
            rendered.replaceSubrange(fullRange, with: replacement)
        }
        return rendered
    }
}

public enum ToolPolicyScanner {
    public static func rejectionReason(script: String, transcript: String = "") -> String? {
        let lowered = script.lowercased()
        let forbidden: [(String, String)] = [
            ("do shell script", "shell commands are not allowed"),
            ("sudo", "sudo is not allowed"),
            ("rm -rf", "recursive deletion is not allowed"),
            ("curl", "network commands are not allowed"),
            ("osascript -e", "nested osascript is not allowed"),
            ("keychain", "Keychain access is not allowed"),
            ("security ", "security commands are not allowed"),
            ("defaults delete", "defaults deletion is not allowed"),
            ("killall", "process termination is not allowed"),
            ("terminal", "Terminal control is not allowed"),
            ("iterm", "terminal control is not allowed"),
            ("shutdown", "shutdown is not allowed"),
            ("restart", "restart is not allowed"),
            ("erase", "erase operations are not allowed"),
            ("diskutil", "disk operations are not allowed"),
            ("nsapplecript", "nested AppleScript is not allowed"),
        ]
        for (needle, reason) in forbidden where lowered.contains(needle) {
            return reason
        }
        if lowered.contains("system events")
            && (lowered.contains("keystroke") || lowered.contains("key code")) {
            return "typing into app windows is not allowed"
        }
        if lowered.contains("tell application \"finder\" to delete") {
            let transcript = transcript.lowercased()
            guard transcript.contains("delete")
                || transcript.contains("trash")
                || transcript.contains("empty") else {
                return "Finder deletion requires an explicit delete or trash request"
            }
        }
        return nil
    }
}
