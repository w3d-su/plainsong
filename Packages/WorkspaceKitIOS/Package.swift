// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WorkspaceKitIOS",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "WorkspaceKitIOS", targets: ["WorkspaceKitIOS"]),
    ],
    dependencies: [
        .package(path: "../MarkdownCore"),
        .package(path: "../WorkspaceCore"),
        .package(path: "../PreviewKit"),
    ],
    targets: [
        .target(
            name: "WorkspaceKitIOS",
            dependencies: [
                .product(name: "MarkdownCore", package: "MarkdownCore"),
                .product(name: "WorkspaceCore", package: "WorkspaceCore"),
                .product(name: "PreviewKitContracts", package: "PreviewKit"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "WorkspaceKitIOSTests", dependencies: ["WorkspaceKitIOS"]),
    ]
)
