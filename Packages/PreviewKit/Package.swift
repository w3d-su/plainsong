// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PreviewKit",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .library(name: "PreviewKit", targets: ["PreviewKit"]),
        .library(name: "PreviewKitContracts", targets: ["PreviewKitContracts"]),
    ],
    dependencies: [
        .package(path: "../MarkdownCore"),
    ],
    targets: [
        .target(
            name: "PreviewKit",
            dependencies: [
                .product(name: "MarkdownCore", package: "MarkdownCore"),
                "PreviewKitContracts",
            ],
            exclude: ["PreviewAssetReading.swift", "PreviewContracts.swift"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "PreviewKitContracts",
            dependencies: [.product(name: "MarkdownCore", package: "MarkdownCore")],
            path: "Sources/PreviewKit",
            sources: ["PreviewAssetReading.swift", "PreviewContracts.swift"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "PreviewKitTests", dependencies: ["PreviewKit"]),
    ]
)
