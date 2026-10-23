// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpeedMerge",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SpeedMergeCore"),
        .executableTarget(name: "SpeedMerge", dependencies: ["SpeedMergeCore"]),
        .testTarget(name: "SpeedMergeCoreTests", dependencies: ["SpeedMergeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
