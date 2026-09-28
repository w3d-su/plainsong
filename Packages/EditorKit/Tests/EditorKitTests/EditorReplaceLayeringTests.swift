import Foundation
import XCTest

final class EditorReplaceLayeringTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testAppAndMarkdownCoreDoNotImportSTTextView() throws {
        let roots = [
            repoRoot.appendingPathComponent("App"),
            repoRoot.appendingPathComponent("Packages/MarkdownCore/Sources"),
        ]
        for root in roots {
            for file in try swiftFiles(under: root) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    XCTAssertNotEqual(
                        line.trimmingCharacters(in: .whitespaces),
                        "import STTextView",
                        file.path
                    )
                }
            }
        }
    }

    func testSingleReplaceDoesNotUseForbiddenMutationAPIs() throws {
        let executor = repoRoot.appendingPathComponent(
            "Packages/EditorKit/Sources/EditorKit/EditorReplaceExecutor.swift"
        )
        let source = try String(contentsOf: executor, encoding: .utf8)
        XCTAssertTrue(source.contains("performPreflightedTextMutation"))
        XCTAssertTrue(source.contains("insertText"))
        for forbidden in [
            "replaceCharacters",
            "STTextFinderClient",
            "replaceDocumentText",
            "mutableString",
            "textStorage?.replace",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func testNoProjectOrPackageDependencyChange() throws {
        let output = try gitDiffNames([
            "project.yml",
            "Packages/EditorKit/Package.swift",
            "Packages/MarkdownCore/Package.swift",
            "preview-src/package.json",
            "preview-src/package-lock.json",
        ])
        XCTAssertEqual(output, "")
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

    private func gitDiffNames(_ paths: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = repoRoot
        process.arguments = ["diff", "--name-only", "origin/main", "--"] + paths
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0)
        let output = String(bytes: data, encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
