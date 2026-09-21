import Foundation
import JevVoiceCore

enum LearnedToolResult<Value> {
    case success(Value)
    case failure(String)
}

struct SynthesizedTool {
    let tool: LearnedTool
    let rounds: Int
}

struct ToolSynthesizer {
    let generator: ContentGenerating
    let jev: JevClient?
    let safetyPolicy: SafetyPolicy?

    func synthesize(transcript: String) async -> LearnedToolResult<SynthesizedTool> {
        var repair: String?
        var policyRejections = 0
        for round in 1...3 {
            do {
                let prompt = Self.prompt(transcript: transcript, repair: repair)
                let json = try await generator.compose(
                    brief: prompt,
                    context: ComposeContext(
                        app: nil,
                        windowTitle: nil,
                        siteHost: nil,
                        maxCharacters: 12000
                    )
                )
                let tool = try Self.decode(json)
                if let reason = Self.policyRejection(tool: tool, transcript: transcript, policy: safetyPolicy) {
                    policyRejections += 1
                    if policyRejections >= 2 {
                        return .failure("I can't script that safely.")
                    }
                    repair = "policy rejected the previous script: \(reason)"
                    continue
                }
                if let compileError = Self.compileError(for: tool, args: Self.sampleArguments(tool)) {
                    repair = "compile failed: \(compileError)"
                    continue
                }
                if let jev, !(await Self.review(tool: tool, transcript: transcript, client: jev)) {
                    repair = "review failed: does more/less than asked"
                    continue
                }
                Log.agent.info(
                    "learned tool synthesized name=\(tool.name, privacy: .public) rounds=\(round)"
                )
                return .success(SynthesizedTool(tool: tool, rounds: round))
            } catch {
                repair = error.localizedDescription
            }
        }
        return .failure("I can't script that safely.")
    }

    static func decode(_ text: String) throws -> LearnedTool {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let data = cleaned.data(using: .utf8) else {
            throw AgentError.invalidResponse
        }
        let tool = try JSONDecoder().decode(LearnedTool.self, from: data)
        guard !tool.name.isEmpty,
              !tool.description.isEmpty,
              !tool.script.isEmpty,
              ["applescript", "javascript"].contains(tool.language.lowercased()),
              tool.arguments.allSatisfy({ ["string", "number", "enum", "boolean"].contains($0.type) })
        else {
            throw AgentError.api("Generated tool schema was invalid")
        }
        return tool
    }

    static func sampleArguments(_ tool: LearnedTool) -> [String: String] {
        Dictionary(uniqueKeysWithValues: tool.arguments.map { argument in
            switch argument.type {
            case "number": return (argument.name, "10")
            case "boolean": return (argument.name, "true")
            case "enum": return (argument.name, argument.values?.first ?? "on")
            default: return (argument.name, "sample text")
            }
        })
    }

    static func policyRejection(
        tool: LearnedTool,
        transcript: String,
        policy: SafetyPolicy?
    ) -> String? {
        if let reason = ToolPolicyScanner.rejectionReason(
            script: tool.script,
            transcript: transcript
        ) {
            return reason
        }
        guard let policy else { return nil }
        let rendered = LearnedTool.render(
            script: tool.script,
            args: sampleArguments(tool),
            arguments: tool.arguments
        )
        for rule in policy.blocked {
            guard let regex = try? NSRegularExpression(
                pattern: rule.pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(location: 0, length: (rendered as NSString).length)
            if regex.firstMatch(in: rendered, range: range) != nil {
                return rule.reason
            }
        }
        return nil
    }

    static func compileError(for tool: LearnedTool, args: [String: String]) -> String? {
        let executable = "/usr/bin/osacompile"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-tool-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("tool.\(tool.language == "javascript" ? "js" : "applescript")")
        let output = directory.appendingPathComponent("compiled.scpt")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try LearnedTool.render(
                script: tool.script,
                args: args,
                arguments: tool.arguments
            ).write(
                to: source,
                atomically: true,
                encoding: .utf8
            )
            let process = Process()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [
                "-l",
                tool.language == "javascript" ? "JavaScript" : "AppleScript",
                "-o",
                output.path,
                source.path,
            ]
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return String(
                    decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func review(tool: LearnedTool, transcript: String, client: JevClient) async -> Bool {
        let state = ReviewState(
            transcript: transcript,
            description: tool.description,
            script: tool.script
        )
        do {
            let response = try await client.systemOne(
                state: state,
                questions: [
                    "review": .noul(
                        instructions: "Does this script do exactly what the request asks — nothing more (no extra deletions, network, or unrelated changes)?"
                    ),
                ]
            ).response
            if case .noul(let probability) = response.answers["review"] {
                return probability >= 0.7
            }
        } catch {
        }
        return false
    }

    private static func prompt(transcript: String, repair: String?) -> String {
        var prompt = """
        Generate one safe macOS automation tool for this request: "\(transcript)".
        Return STRICT JSON only with this schema:
        {"name":"toggle_dark_mode","description":"...","language":"applescript","arguments":[{"name":"state","type":"enum","values":["on","off"],"description":"..."}],"script":"...","spokenResult":"...","mutates":true,"verifyScript":"...","utteranceExamples":["..."]}
        Types are string, number, enum, or boolean. Use {{argName}} placeholders.
        Do not operate app windows with mouse or keyboard. Do not use shell commands, network,
        credentials, terminal apps, or unrelated changes.
        """
        if let repair {
            prompt += "\nRepair the previous attempt because: \(repair)"
        }
        return prompt
    }
}

private struct ReviewState: Encodable {
    let transcript: String
    let description: String
    let script: String
}
