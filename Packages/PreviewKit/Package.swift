// swift-tools-version: 6.0
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
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PreviewKitContracts",
            dependencies: [.product(name: "MarkdownCore", package: "MarkdownCore")],
            path: "Sources/PreviewKit",
            sources: ["PreviewAssetReading.swift", "PreviewContracts.swift"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "PreviewKitTests", dependencies: ["PreviewKit"]),
    ],
    swiftLanguageModes: [.v5]
)
