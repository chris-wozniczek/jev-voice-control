import Foundation
import XCTest
@testable import JevVoice
@testable import JevVoiceCore

final class LearnedToolTests: XCTestCase {
    func testRenderEscapesStringsAndKeepsNumbersRaw() {
        let script = "set value {{text}} and number {{amount}} and flag {{state == on}}"
        let rendered = LearnedTool.render(
            script: script,
            args: ["text": "say \"hi\"", "amount": "42", "state": "on"]
        )
        XCTAssertEqual(
            rendered,
            #"set value "say \"hi\"" and number 42 and flag true"#
        )
    }

    func testPolicyScannerRejectsUnsafeOperations() {
        XCTAssertNotNil(ToolPolicyScanner.rejectionReason(script: "do shell script \"rm -rf /\""))
        XCTAssertNotNil(
            ToolPolicyScanner.rejectionReason(
                script: #"tell application "System Events" to keystroke "x""#
            )
        )
        XCTAssertNil(
            ToolPolicyScanner.rejectionReason(
                script: #"tell application "Finder" to delete every item of folder "Downloads" of home"#,
                transcript: "empty my Downloads"
            )
        )
        XCTAssertNotNil(
            ToolPolicyScanner.rejectionReason(
                script: #"tell application "Finder" to delete every item of folder "Downloads" of home"#,
                transcript: "show my Downloads"
            )
        )
    }

    func testStringArgumentExtractorUsesTextAfterRequestMarker() {
        let tool = LearnedTool(
            name: "add_reminder",
            description: "Add a reminder",
            language: "applescript",
            arguments: [
                LearnedToolArgument(name: "text", type: "string")
            ],
            script: "",
            spokenResult: "",
            mutates: true
        )
        XCTAssertEqual(
            ToolExecutor.stringArgument(
                name: "text",
                transcript: "remind me to buy milk",
                tool: tool
            ),
            "buy milk"
        )
    }

    func testSeedToolsPassPolicyAndCompileWhenAvailable() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/JevVoice/Resources/seed-tools.json")
        let tools = try JSONDecoder().decode(
            [LearnedTool].self,
            from: Data(contentsOf: url)
        )
        for tool in tools {
            XCTAssertNil(
                ToolPolicyScanner.rejectionReason(
                    script: LearnedTool.render(
                        script: tool.script,
                        args: Dictionary(uniqueKeysWithValues: tool.arguments.map {
                            ($0.name, $0.type == "number" ? "10" : ($0.values?.first ?? "sample"))
                        })
                    ),
                    transcript: tool.utteranceExamples.first ?? ""
                ),
                tool.name
            )
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/osacompile") else {
                continue
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("tool.scpt")
            let output = directory.appendingPathComponent("tool.compiled")
            try LearnedTool.render(
                script: tool.script,
                args: Dictionary(uniqueKeysWithValues: tool.arguments.map {
                    ($0.name, $0.type == "number" ? "10" : ($0.values?.first ?? "sample"))
                })
            ).write(to: source, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = [
                "-l",
                tool.language == "javascript" ? "JavaScript" : "AppleScript",
                "-o",
                output.path,
                source.path,
            ]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, tool.name)
        }
    }
}
