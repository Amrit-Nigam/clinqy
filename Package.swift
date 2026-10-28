// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clinqy",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ObjCCatch", path: "Sources/ObjCCatch"),
        .executableTarget(
            name: "Clinqy",
            dependencies: ["ObjCCatch"],
            path: "Sources/Clinqy",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
