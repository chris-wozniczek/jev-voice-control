import Foundation
import JevVoiceCore

struct ToolExecutor {
    static func arguments(
        for tool: LearnedTool,
        transcript: String,
        jev: JevClient?
    ) async -> LearnedToolResult<[String: String]> {
        var values: [String: String] = [:]
        for argument in tool.arguments {
            switch argument.type {
            case "enum":
                guard let jev else {
                    return .failure("I need a \(argument.name)")
                }
                let criteria = Dictionary(
                    uniqueKeysWithValues: (argument.values ?? []).map { ($0, Optional<String>.none) }
                )
                do {
                    let response = try await jev.systemOne(
                        state: ArgumentState(transcript: transcript, argument: argument.name),
                        questions: [
                            "value": .choice(
                                instructions: "Which value for \(argument.name) is requested?",
                                criteria: criteria
                            ),
                        ]
                    ).response
                    guard case .choice(let choice, let confidence, _) = response.answers["value"],
                          confidence >= 0.7,
                          (argument.values ?? []).contains(where: {
                              $0.caseInsensitiveCompare(choice) == .orderedSame
                          }) else {
                        return .failure("I need a \(argument.name)")
                    }
                    values[argument.name] = choice
                } catch {
                    return .failure("I need a \(argument.name)")
                }
            case "number":
                guard let match = transcript.range(
                    of: #"\b\d+(?:\.\d+)?\s*%?"#,
                    options: .regularExpression
                ) else {
                    return .failure("I need a \(argument.name)")
                }
                values[argument.name] = transcript[match]
                    .replacingOccurrences(of: "%", with: "")
                    .trimmingCharacters(in: .whitespaces)
            case "boolean":
                let lowered = transcript.lowercased()
                if lowered.contains("true") || lowered.contains(" on") || lowered.hasSuffix("on") {
                    values[argument.name] = "true"
                } else if lowered.contains("false") || lowered.contains(" off") || lowered.hasSuffix("off") {
                    values[argument.name] = "false"
                } else {
                    return .failure("I need a \(argument.name)")
                }
            default:
                guard let text = Self.stringArgument(
                    name: argument.name,
                    transcript: transcript,
                    tool: tool
                ), !text.isEmpty else {
                    return .failure("I need a \(argument.name)")
                }
                values[argument.name] = text
            }
        }
        return .success(values)
    }

    static func stringArgument(
        name: String,
        transcript: String,
        tool: LearnedTool
    ) -> String? {
        let lowered = transcript.lowercased()
        let markers = ["remind me to", "called", "named", "titled", "to", "about"]
        for marker in markers {
            guard let range = lowered.range(of: marker) else { continue }
            var remainder = String(transcript[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.localizedCaseInsensitiveContains("time"),
               let at = remainder.range(of: #"\bat\b"#, options: .regularExpression) {
                remainder = String(remainder[at.upperBound...])
            }
            if name.localizedCaseInsensitiveContains("title"),
               let at = remainder.range(of: #"\bat\b"#, options: .regularExpression) {
                remainder = String(remainder[..<at.lowerBound])
            }
            if !remainder.isEmpty {
                return remainder.trimmingCharacters(in: CharacterSet(charactersIn: " .?!"))
            }
        }
        let knownWords = Set(
            ([tool.name, tool.description] + tool.utteranceExamples)
                .flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
                .map(String.init)
        )
        let remainder = transcript
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !knownWords.contains($0.lowercased()) }
            .joined(separator: " ")
        return remainder.isEmpty ? nil : remainder
    }

    @MainActor
    static func execute(
        tool: LearnedTool,
        args: [String: String],
        transcript: String,
        store: LearnedToolStore,
        jev: JevClient?,
        safetyPolicy: SafetyPolicy?,
        cached: Bool = true,
        rounds: Int = 1
    ) async -> LearnedToolResult<String> {
        let started = Date()
        let rendered = LearnedTool.render(script: tool.script, args: args)
        if let reason = ToolPolicyScanner.rejectionReason(
            script: rendered,
            transcript: transcript
        ) {
            return .failure("I can't script that safely: \(reason)")
        }
        if let safetyPolicy,
           safetyPolicy.blocked.contains(where: { rule in
               guard let regex = try? NSRegularExpression(
                   pattern: rule.pattern,
                   options: [.caseInsensitive]
               ) else { return false }
               return regex.firstMatch(
                   in: rendered,
                   range: NSRange(location: 0, length: (rendered as NSString).length)
               ) != nil
           }) {
            return .failure("I can't script that safely")
        }
        do {
            let output = try await run(
                language: tool.language,
                script: rendered,
                timeout: 15
            )
            guard output.status == 0 else {
                return .failure(output.stderr.isEmpty ? "The tool failed" : output.stderr)
            }
            var verifyOutput = ""
            if let verifyScript = tool.verifyScript {
                verifyOutput = try await run(
                    language: tool.language,
                    script: LearnedTool.render(script: verifyScript, args: args),
                    timeout: 15
                ).stdout
                if let jev {
                    let verified = await verify(
                        transcript: transcript,
                        expected: spokenResult(tool.spokenResult, args: args),
                        output: verifyOutput,
                        client: jev
                    )
                    if !verified {
                        return .failure("The tool ran, but I couldn't verify the result")
                    }
                }
            }
            store.save(tool)
            let spoken = spokenResult(tool.spokenResult, args: args)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Log.agent.info(
                "stage=tool name=\(tool.name, privacy: .public) cached=\(cached) gates=compile,policy,review rounds=\(rounds) elapsed=\(elapsed)"
            )
            return .success(spoken)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func spokenResult(_ template: String, args: [String: String]) -> String {
        args.reduce(template) { result, pair in
            result.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value)
        }
    }

    private static func verify(
        transcript: String,
        expected: String,
        output: String,
        client: JevClient
    ) async -> Bool {
        do {
            let response = try await client.systemOne(
                state: VerificationState(
                    transcript: transcript,
                    expected: expected,
                    verifyOutput: output
                ),
                questions: [
                    "fulfilled": .noul(
                        instructions: "Does the output show the request was fulfilled?"
                    ),
                ]
            ).response
            if case .noul(let probability) = response.answers["fulfilled"] {
                return probability >= 0.6
            }
        } catch {}
        return false
    }

    private static func run(
        language: String,
        script: String,
        timeout: TimeInterval
    ) async throws -> ProcessOutput {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-tool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-l",
            language == "javascript" ? "JavaScript" : "AppleScript",
            file.path,
        ]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        return ProcessOutput(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private struct ProcessOutput {
    let status: Int32
    let stdout: String
    let stderr: String
}

private struct ArgumentState: Encodable {
    let transcript: String
    let argument: String
}

private struct VerificationState: Encodable {
    let transcript: String
    let expected: String
    let verifyOutput: String
}
