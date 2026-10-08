// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EditorKitIOS",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "EditorKitIOS", targets: ["EditorKitIOS"]),
    ],
    dependencies: [
        .package(path: "../MarkdownCore"),
        .package(path: "../SyntaxKit"),
    ],
    targets: [
        .target(
            name: "EditorKitIOS",
            dependencies: [
                .product(name: "MarkdownCore", package: "MarkdownCore"),
                .product(name: "SyntaxKit", package: "SyntaxKit"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "EditorKitIOSTests", dependencies: ["EditorKitIOS"]),
    ]
)
