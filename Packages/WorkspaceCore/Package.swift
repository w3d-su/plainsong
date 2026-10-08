// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WorkspaceCore",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .library(name: "WorkspaceCore", targets: ["WorkspaceCore"]),
    ],
    dependencies: [
        .package(path: "../MarkdownCore"),
    ],
    targets: [
        .target(
            name: "WorkspaceCore",
            dependencies: [
                .product(name: "MarkdownCore", package: "MarkdownCore"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "WorkspaceCoreTests", dependencies: ["WorkspaceCore"]),
    ]
)
