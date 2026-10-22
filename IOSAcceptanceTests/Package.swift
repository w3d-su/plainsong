// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "IOSAcceptanceHarness",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .library(name: "IOSAcceptanceHarness", targets: ["IOSAcceptanceHarness"]),
    ],
    dependencies: [
        .package(path: "../Packages/MarkdownCore"),
        .package(path: "../Packages/WorkspaceCore"),
        .package(path: "../Packages/PreviewKit"),
    ],
    targets: [
        .target(
            name: "IOSAcceptanceHarness",
            dependencies: [
                .product(name: "MarkdownCore", package: "MarkdownCore"),
                .product(name: "WorkspaceCore", package: "WorkspaceCore"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "IOSAcceptanceHarnessTests",
            dependencies: [
                "IOSAcceptanceHarness",
                .product(name: "MarkdownCore", package: "MarkdownCore"),
                .product(name: "WorkspaceCore", package: "WorkspaceCore"),
                .product(name: "PreviewKit", package: "PreviewKit"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
