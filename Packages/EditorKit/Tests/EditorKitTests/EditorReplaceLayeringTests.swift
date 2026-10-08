import Foundation
import XCTest

/// Source-level R2 assertions. They read checked-in files only: no git refs,
/// network, or tool on PATH, so a detached or shallow CI checkout gives the
/// same answer as a local clone.
final class EditorReplaceLayeringTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// No `import STTextView` and no `STText*` identifier outside comments.
    func testAppAndMarkdownCoreDoNotImportSTTextView() throws {
        let roots = [
            repoRoot.appendingPathComponent("App"),
            repoRoot.appendingPathComponent("AppIOS"),
            repoRoot.appendingPathComponent("Packages/MarkdownCore/Sources"),
        ]
        let typeName = try NSRegularExpression(pattern: #"\bSTText\w*"#)
        for root in roots {
            for file in try swiftFiles(under: root) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let code = Self.strippingLineComment(String(line))
                        .trimmingCharacters(in: .whitespaces)
                    XCTAssertNotEqual(code, "import STTextView", file.path)
                    let range = NSRange(code.startIndex..., in: code)
                    XCTAssertNil(
                        typeName.firstMatch(in: code, range: range),
                        "\(file.lastPathComponent): \(code)"
                    )
                }
            }
        }
    }

    /// R7: EditorKit consumes App's plain authorization closure without importing App or
    /// WorkspaceKit; the App decision never reaches EditorKit as a type.
    func testEditorKitImportsNeitherAppNorWorkspaceKit() throws {
        let root = repoRoot.appendingPathComponent("Packages/EditorKit/Sources")
        for file in try swiftFiles(under: root) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = Self.strippingLineComment(String(line))
                    .trimmingCharacters(in: .whitespaces)
                XCTAssertFalse(code.hasPrefix("import Plainsong"), "\(file.lastPathComponent): \(code)")
                XCTAssertFalse(code.hasPrefix("import WorkspaceKit"), "\(file.lastPathComponent): \(code)")
                XCTAssertFalse(
                    code.contains("EditorReplaceAuthorizationDecision"),
                    "\(file.lastPathComponent): \(code)"
                )
            }
        }
    }

    func testSingleReplaceDoesNotUseForbiddenMutationAPIs() throws {
        let executor = try source("Packages/EditorKit/Sources/EditorKit/EditorReplaceExecutor.swift")
        XCTAssertTrue(executor.contains("performPreflightedTextMutation"))
        XCTAssertTrue(executor.contains("insertText"))
        let replacementSources = try [
            executor,
            source("Packages/EditorKit/Sources/EditorKit/EditorFindController+Replacement.swift"),
            source("Packages/EditorKit/Sources/EditorKit/EditorReplaceCommandDispatcher.swift"),
            source("Packages/EditorKit/Sources/EditorKit/EditorReplaceRejectedWriteUndo.swift"),
        ]
        for text in replacementSources {
            for forbidden in [
                "replaceCharacters",
                "STTextFinderClient",
                "replaceDocumentText",
                "mutableString",
                "textStorage?.replace",
                "wrappedValue",
                "setString",
                "EditingBehaviorProposal",
            ] {
                XCTAssertFalse(text.contains(forbidden), forbidden)
            }
        }
    }

    /// R2: no new Swift/npm dependency or project-target change. Pins the
    /// dependency declarations themselves; a later PR that adds one updates
    /// this list together with its Decision Log row (`agent.md` §17.7).
    func testNoProjectOrPackageDependencyChange() throws {
        XCTAssertEqual(try swiftPackageDeclarations(), [
            "EditorKit": [
                #".package(path: "../MarkdownCore")"#,
                #".package(path: "../SyntaxKit")"#,
                #".package(url: "https://github.com/krzyzanowskim/STTextView.git", exact: "2.3.10")"#,
                #".package(url: "https://github.com/tree-sitter/swift-tree-sitter.git", exact: "0.10.0")"#,
                #".package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown.git", exact: "0.5.3")"#,
            ],
            "MarkdownCore": [
                #".package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")"#,
            ],
            "PreviewKit": [#".package(path: "../MarkdownCore")"#],
            "WorkspaceKit": [#".package(path: "../MarkdownCore")"#],
            "SyntaxKit": [#".package(path: "../MarkdownCore")"#],
            "WorkspaceCore": [#".package(path: "../MarkdownCore")"#],
            "EditorKitIOS": [#".package(path: "../MarkdownCore")"#, #".package(path: "../SyntaxKit")"#],
            "WorkspaceKitIOS": [
                #".package(path: "../MarkdownCore")"#,
                #".package(path: "../WorkspaceCore")"#,
                #".package(path: "../PreviewKit")"#,
            ],
        ])

        let project = try projectManifest()
        XCTAssertEqual(project.packages, [
            "EditorKit", "MarkdownCore", "PreviewKit", "WorkspaceKit", "Yams",
            "SyntaxKit", "WorkspaceCore", "EditorKitIOS", "WorkspaceKitIOS",
        ])
        XCTAssertEqual(project.targets, [
            "PerformanceTests", "Plainsong", "PlainsongTests", "PlainsongUITests",
            "PlainsongIOS", "PlainsongIOSTests",
        ])
        XCTAssertEqual(project.dependencies, [
            "package: EditorKit",
            "package: MarkdownCore",
            "package: PreviewKit",
            "package: WorkspaceKit",
            "sdk: PDFKit.framework",
            "target: Plainsong",
            "target: PlainsongIOS",
            "package: SyntaxKit",
            "package: WorkspaceCore",
            "package: EditorKitIOS",
            "package: WorkspaceKitIOS",
            "package: MarkdownCore/MarkdownCoreTests",
            "package: SyntaxKit/SyntaxKitTests",
            "package: WorkspaceCore/WorkspaceCoreTests",
            "package: EditorKitIOS/EditorKitIOSTests",
            "package: WorkspaceKitIOS/WorkspaceKitIOSTests",
        ])

        let npm = try npmDependencyNames()
        XCTAssertEqual(npm.runtime, [
            "highlight.js", "mdast-util-mdx", "mermaid", "morphdom", "rehype-katex",
            "rehype-sanitize", "rehype-stringify", "remark-frontmatter", "remark-gfm",
            "remark-math", "remark-mdx", "remark-parse", "remark-rehype", "unified",
        ])
        XCTAssertEqual(npm.development, ["esbuild", "jsdom", "typescript", "vitest"])
    }

    /// C0 must compile declarations without linking the Mac editor/workspace or
    /// unfinished PreviewKit UIKit implementation. 13 owns this architecture pin.
    func testIOSScaffoldDoesNotLinkMacOnlyProviders() throws {
        let project = try source("project.yml")
        let app = try XCTUnwrap(project.components(separatedBy: "\n  PlainsongIOS:").dropFirst().first)
            .components(separatedBy: "\n  PlainsongIOSTests:")[0]
        XCTAssertTrue(app.contains("product: PreviewKitContracts"))
        XCTAssertFalse(app.contains("- package: EditorKit\n"))
        XCTAssertFalse(app.contains("- package: WorkspaceKit\n"))
        for package in ["MarkdownCore", "SyntaxKit", "WorkspaceCore"] {
            for file in try swiftFiles(under: repoRoot.appendingPathComponent("Packages/\(package)/Sources")) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for line in text.split(separator: "\n") {
                    let code = Self.strippingLineComment(String(line)).trimmingCharacters(in: .whitespaces)
                    for module in ["AppKit", "UIKit", "WebKit"] {
                        XCTAssertNotEqual(code, "import \(module)", file.path)
                    }
                }
            }
        }
    }

    // MARK: - Manifest readers

    private func swiftPackageDeclarations() throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for name in [
            "EditorKit", "MarkdownCore", "PreviewKit", "WorkspaceKit",
            "SyntaxKit", "WorkspaceCore", "EditorKitIOS", "WorkspaceKitIOS",
        ] {
            let manifest = try source("Packages/\(name)/Package.swift")
            result[name] = manifest
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix(".package(") }
                .map { $0.hasSuffix(",") ? String($0.dropLast()) : $0 }
        }
        return result
    }

    private struct ProjectManifest {
        var packages: Set<String> = []
        var targets: Set<String> = []
        var dependencies: Set<String> = []
    }

    /// Reads the keys of the top-level XcodeGen `packages:` and `targets:` maps
    /// plus every `- package:` / `- target:` / `- sdk:` dependency line.
    /// Settings, sources, and Info.plist values are deliberately not pinned.
    private func projectManifest() throws -> ProjectManifest {
        var manifest = ProjectManifest()
        var section: String?
        for rawLine in try source("project.yml").split(separator: "\n") {
            let line = String(rawLine)
            if !line.hasPrefix(" "), !line.hasPrefix("#") {
                section = line.hasSuffix(":") ? String(line.dropLast()) : nil
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("  "), !line.hasPrefix("   "), trimmed.hasSuffix(":") {
                let key = String(trimmed.dropLast())
                if section == "packages" {
                    manifest.packages.insert(key)
                } else if section == "targets" {
                    manifest.targets.insert(key)
                }
            }
            for kind in ["package", "target", "sdk"] where trimmed.hasPrefix("- \(kind): ") {
                manifest.dependencies.insert(String(trimmed.dropFirst(2)))
            }
        }
        return manifest
    }

    private func npmDependencyNames() throws -> (runtime: Set<String>, development: Set<String>) {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("preview-src/package.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let runtime = (object["dependencies"] as? [String: Any]).map { Set($0.keys) } ?? []
        let development = (object["devDependencies"] as? [String: Any]).map { Set($0.keys) } ?? []
        return (runtime, development)
    }

    // MARK: - Files

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func strippingLineComment(_ line: String) -> String {
        guard let marker = line.range(of: "//") else { return line }
        return String(line[..<marker.lowerBound])
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        XCTAssertFalse(files.isEmpty, root.path)
        return files
    }
}
