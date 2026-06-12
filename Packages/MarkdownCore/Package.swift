// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MarkdownCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownCore", targets: ["MarkdownCore"]),
    ],
    targets: [
        .target(
            name: "MarkdownCore",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "MarkdownCoreTests", dependencies: ["MarkdownCore"]),
    ]
)
