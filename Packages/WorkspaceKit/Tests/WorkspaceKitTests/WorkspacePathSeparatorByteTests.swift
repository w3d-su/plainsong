import Foundation
@testable import WorkspaceKit
import XCTest

/// `/` followed by a combining scalar is one `Character` that is not `"/"`, but the kernel
/// splits the path at the `0x2F` byte. Every case here hides a separator that way.
final class WorkspacePathSeparatorByteTests: XCTestCase {
    private let combining = "\u{0301}"

    func testSymlinkComponentBeforeACombiningScalarIsNotFollowed() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        let leaf = "\(combining)post.md"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "outside".write(to: outside.appendingPathComponent(leaf), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )

        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "link/\(leaf)")

        XCTAssertEqual(WorkspaceNoFollowFileInspector.status(at: location), .symbolicLink)
        XCTAssertThrowsError(try MarkdownFileStore().load(at: location))
    }

    func testLocationRejectsAbsoluteAndParentPathsHiddenBehindACombiningScalar() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)

        XCTAssertThrowsError(try authority.location(relativePath: "/\(combining)etc/hosts"))
        XCTAssertThrowsError(try authority.location(relativePath: "../\(combining)secret"))
        XCTAssertThrowsError(try WorkspaceRootContainment.normalizedRelativePath("../\(combining)secret"))
        XCTAssertThrowsError(try WorkspaceRootContainment.normalizedRelativePath("/\(combining)etc"))
    }

    func testFileWhoseNameStartsWithACombiningScalarLoads() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("posts", isDirectory: true)
        let leaf = "\(combining)post.md"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "body".write(to: directory.appendingPathComponent(leaf), atomically: true, encoding: .utf8)

        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "posts/\(leaf)")

        XCTAssertEqual(try MarkdownFileStore().load(at: location).text, "body")
        XCTAssertEqual(
            try WorkspaceLiteralFileURL.leafName(of: location.fileURL.path(percentEncoded: false)).utf8.map(\.self),
            leaf.utf8.map(\.self)
        )
    }

    func testPrimitivesRefuseANameThatIsNotOneComponent() {
        XCTAssertThrowsError(try WorkspaceAnchoredFileSystem.requireSingleComponent("a/\(combining)b"))
        XCTAssertThrowsError(try WorkspaceAnchoredFileSystem.requireSingleComponent("/\(combining)etc"))
        XCTAssertThrowsError(try WorkspaceAnchoredFileSystem.requireSingleComponent(""))
        XCTAssertNoThrow(try WorkspaceAnchoredFileSystem.requireSingleComponent("\(combining)b"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePathSeparatorByteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
