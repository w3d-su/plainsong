import Foundation
@testable import PreviewKit
import XCTest

/// The base directory is computed in the same symlink-resolved space the containment
/// check uses, so a root and a file spelled through different links still pair up.
final class AssetContextSymlinkTests: XCTestCase {
    func testBaseDirSurvivesARootSpelledThroughASymlink() throws {
        let (link, real) = try linkedRoot()
        let file = real.appendingPathComponent("content/posts/post.md")

        let context = PreviewController.assetContext(fileURL: file, workspaceRootURL: link)

        XCTAssertEqual(context.allowedRoot, link.standardizedFileURL)
        XCTAssertEqual(context.baseDir, "content/posts")
    }

    func testBaseDirSurvivesAFileSpelledThroughASymlink() throws {
        let (link, real) = try linkedRoot()
        let file = link.appendingPathComponent("content/posts/post.md")

        let context = PreviewController.assetContext(fileURL: file, workspaceRootURL: real)

        XCTAssertEqual(context.baseDir, "content/posts")
    }

    func testGrantedBaseDirSurvivesARootSpelledThroughASymlink() throws {
        let (link, real) = try linkedRoot()
        let file = real.appendingPathComponent("content/post.md")
        let access = PreviewAssetTestSupport.access(root: link, generation: 1)

        let context = PreviewController.grantedAssetContext(fileURL: file, access: access)

        XCTAssertEqual(context.baseDir, "content")
    }

    func testFileOutsideTheGrantedRootStillHasNoBaseDir() throws {
        let (link, real) = try linkedRoot()
        let outside = real.deletingLastPathComponent().appendingPathComponent("elsewhere/post.md")
        let access = PreviewAssetTestSupport.access(root: link, generation: 1)

        XCTAssertNil(PreviewController.grantedAssetContext(fileURL: outside, access: access).baseDir)
    }

    private func linkedRoot() throws -> (link: URL, real: URL) {
        let parent = try PreviewAssetTestSupport.directory().resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let real = parent.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("content/posts", isDirectory: true),
            withIntermediateDirectories: true
        )
        for path in ["content/posts/post.md", "content/post.md"] {
            try Data("# Post\n".utf8).write(to: real.appendingPathComponent(path))
        }
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        return (link, real)
    }
}
