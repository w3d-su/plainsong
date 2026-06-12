// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WorkspaceKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkspaceKit", targets: ["WorkspaceKit"]),
    ],
    dependencies: [
        .package(path: "../MarkdownCore"),
    ],
    targets: [
        .target(
            name: "WorkspaceKit",
            dependencies: [.product(name: "MarkdownCore", package: "MarkdownCore")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "WorkspaceKitTests", dependencies: ["WorkspaceKit"]),
    ]
)
