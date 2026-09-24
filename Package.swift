// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CursorBoy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CursorBoy",
            path: "Sources/CursorBoy",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
