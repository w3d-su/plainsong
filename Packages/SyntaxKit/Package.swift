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
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter.git", exact: "0.10.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown.git", exact: "0.5.3"),
    ],
    targets: [
        .target(
            name: "SyntaxKit",
            dependencies: [
                .product(name: "MarkdownCore", package: "MarkdownCore"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                "TreeSitterTSXFixed",
                "TreeSitterYAMLFixed",
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "TreeSitterTSXFixed",
            path: "Sources/TreeSitterTSXFixed",
            sources: [
                "src/parser.c",
                "src/scanner.c",
            ],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "TreeSitterYAMLFixed",
            path: "Sources/TreeSitterYAMLFixed",
            sources: [
                "src/parser.c",
                "src/scanner.c",
            ],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .testTarget(name: "SyntaxKitTests", dependencies: ["SyntaxKit"]),
    ]
)
