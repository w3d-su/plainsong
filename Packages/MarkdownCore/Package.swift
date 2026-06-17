// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MarkdownCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownCore", targets: ["MarkdownCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        .target(
            name: "MarkdownCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "MarkdownCoreTests", dependencies: ["MarkdownCore"]),
    ]
)
