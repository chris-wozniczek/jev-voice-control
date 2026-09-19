// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JevVoice",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "JevVoiceCore",
            path: "Sources/JevVoiceCore"
        ),
        .executableTarget(
            name: "JevVoice",
            dependencies: ["JevVoiceCore"],
            path: "Sources/JevVoice"
        ),
        .testTarget(
            name: "JevVoiceTests",
            dependencies: ["JevVoiceCore", "JevVoice"],
            path: "Tests/JevVoiceTests"
        ),
    ]
)
