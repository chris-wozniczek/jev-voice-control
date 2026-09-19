// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JevVoice",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "JevVoiceCore",
            path: "Sources/JevVoiceCore"
        ),
        .executableTarget(
            name: "JevVoice",
            dependencies: [
                "JevVoiceCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/JevVoice"
        ),
        .testTarget(
            name: "JevVoiceTests",
            dependencies: ["JevVoiceCore", "JevVoice"],
            path: "Tests/JevVoiceTests"
        ),
    ]
)
