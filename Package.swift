// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clinqy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clinqy",
            path: "Sources/Clinqy",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
