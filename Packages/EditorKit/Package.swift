// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EditorKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EditorKit", targets: ["EditorKit"]),
    ],
    dependencies: [
        .package(path: "../MarkdownCore"),
        // M1 adds: STTextView, Neon, SwiftTreeSitter + grammars (agent.md §2).
    ],
    targets: [
        .target(
            name: "EditorKit",
            dependencies: [.product(name: "MarkdownCore", package: "MarkdownCore")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "EditorKitTests", dependencies: ["EditorKit"]),
    ]
)
