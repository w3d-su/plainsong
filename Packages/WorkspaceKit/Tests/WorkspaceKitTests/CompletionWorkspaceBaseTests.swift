@testable import WorkspaceKit
import XCTest

/// The cached workspace half of completion metadata and its bounded sibling reads.
final class CompletionWorkspaceBaseTests: XCTestCase {
    func testCachedBaseComposesToTheFullWorkspace() async throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("page.mdx")
        let currentText = "import Card from \"./Card\"\n\n# Title\n"
        try currentText.write(to: currentFile, atomically: true, encoding: .utf8)
        try "---\nlayout: post\n---\nBody".write(
            to: root.appendingPathComponent("sibling.md"),
            atomically: true,
            encoding: .utf8
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("hero.png"))
        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let location = try capture.rootAuthority.canonicalizedLocation(forFileURL: currentFile)
        let provider = CompletionWorkspaceProvider()

        let base = try provider.workspaceBase(
            rootAuthority: capture.rootAuthority,
            currentFileLocation: location,
            snapshot: capture.snapshot
        )
        let editedText = currentText + "\n## Added Section\n"

        XCTAssertEqual(
            provider.workspace(base: base, currentText: editedText),
            try provider.workspace(
                rootAuthority: capture.rootAuthority,
                currentFileLocation: location,
                currentText: editedText,
                snapshot: capture.snapshot
            )
        )
        XCTAssertEqual(
            provider.workspace(base: base, currentText: editedText).currentFileHeadingAnchors,
            ["#title", "#added-section"]
        )
        XCTAssertEqual(provider.workspace(base: base, currentText: editedText).componentNames, ["Card"])
        XCTAssertEqual(base.frontmatterKeys, ["layout"])
    }

    func testSiblingFrontmatterReadStopsAtTheBoundedPrefix() async throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("current.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        // Bytes past the prefix are not UTF-8. A whole-file read rejected this sibling.
        let limit = CompletionWorkspaceProvider.siblingFrontmatterPrefixByteLimit
        var sibling = Data("---\nprefix_key: value\n---\n".utf8)
        sibling.append(Data(repeating: UInt8(ascii: "x"), count: limit - sibling.count))
        sibling.append(Data(repeating: 0xFF, count: 1024))
        try sibling.write(to: root.appendingPathComponent("large.md"))
        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)

        let workspace = try CompletionWorkspaceProvider().workspace(
            rootAuthority: capture.rootAuthority,
            currentFileLocation: capture.rootAuthority.canonicalizedLocation(forFileURL: currentFile),
            currentText: "Body",
            snapshot: capture.snapshot
        )

        XCTAssertEqual(workspace.frontmatterKeys, ["prefix_key"])
    }

    func testBoundedPrefixDecodingDropsOnlyAnIncompleteTrailingScalar() {
        let complete = Data("key: \u{6F22}".utf8)
        XCTAssertEqual(
            CompletionWorkspaceProvider.decodedUTF8Prefix(complete, mayEndInsideScalar: true),
            "key: \u{6F22}"
        )
        for cut in 1 ... 2 {
            XCTAssertEqual(
                CompletionWorkspaceProvider.decodedUTF8Prefix(
                    complete.dropLast(cut),
                    mayEndInsideScalar: true
                ),
                "key: "
            )
            XCTAssertNil(CompletionWorkspaceProvider.decodedUTF8Prefix(
                complete.dropLast(cut),
                mayEndInsideScalar: false
            ))
        }
        var invalidInside = Data("ke".utf8)
        invalidInside.append(0xFF)
        invalidInside.append(contentsOf: Data("y: value".utf8))
        XCTAssertNil(CompletionWorkspaceProvider.decodedUTF8Prefix(
            invalidInside,
            mayEndInsideScalar: true
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletionWorkspaceBaseTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
