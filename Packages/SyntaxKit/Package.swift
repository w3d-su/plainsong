// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SyntaxKit",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .library(name: "SyntaxKit", targets: ["SyntaxKit"]),
    ],
    dependencies: [
        .package(path: "../MarkdownCore"),
    ],
    targets: [
        .target(
            name: "SyntaxKit",
            dependencies: [
                .product(name: "MarkdownCore", package: "MarkdownCore"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "SyntaxKitTests", dependencies: ["SyntaxKit"]),
    ]
)
