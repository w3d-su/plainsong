// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorkspaceKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkspaceKit", targets: ["WorkspaceKit"]),
    ],
    dependencies: [
        .package(path: "../MarkdownCore"),
        .package(path: "../WorkspaceCore"),
    ],
    targets: [
        .target(
            name: "WorkspaceKit",
            dependencies: [
                .product(name: "MarkdownCore", package: "MarkdownCore"),
                .product(name: "WorkspaceCore", package: "WorkspaceCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WorkspaceKitTests",
            dependencies: ["WorkspaceKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
