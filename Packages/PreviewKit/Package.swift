// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PreviewKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PreviewKit", targets: ["PreviewKit"]),
    ],
    dependencies: [
        .package(path: "../MarkdownCore"),
    ],
    targets: [
        .target(
            name: "PreviewKit",
            dependencies: [.product(name: "MarkdownCore", package: "MarkdownCore")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "PreviewKitTests", dependencies: ["PreviewKit"]),
    ]
)
