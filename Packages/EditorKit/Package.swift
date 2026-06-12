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
        .package(url: "https://github.com/krzyzanowskim/STTextView.git", exact: "2.3.10"),
        // M1.5 adds: Neon, SwiftTreeSitter + grammars (agent.md §2).
    ],
    targets: [
        .target(
            name: "EditorKit",
            dependencies: [
                .product(name: "MarkdownCore", package: "MarkdownCore"),
                .product(name: "STTextView", package: "STTextView"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "EditorKitTests", dependencies: ["EditorKit"]),
    ]
)
