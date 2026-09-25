// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clinqy",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Local Whisper speech-to-text on Apple silicon (Core ML), the same model family Superwhisper uses.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Clinqy",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/Clinqy",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
