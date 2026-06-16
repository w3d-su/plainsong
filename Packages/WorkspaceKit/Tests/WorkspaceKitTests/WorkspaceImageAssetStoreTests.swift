@testable import WorkspaceKit
import XCTest

final class WorkspaceImageAssetStoreTests: XCTestCase {
    func testInsideWorkspaceImageReturnsRelativePathWithoutCopying() throws {
        let root = try makeTemporaryDirectory()
        let posts = root.appendingPathComponent("posts", isDirectory: true)
        let sharedAssets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: posts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedAssets, withIntermediateDirectories: true)
        let currentFile = posts.appendingPathComponent("post.md")
        let image = sharedAssets.appendingPathComponent("logo.png")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: image)

        let paths = try WorkspaceImageAssetStore().place(
            [.file(image)],
            rootURL: root,
            currentFileURL: currentFile
        )

        XCTAssertEqual(paths, ["../assets/logo.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: posts.appendingPathComponent("assets/logo.png").path))
    }

    func testOutsideWorkspaceImageCopiesIntoAssetsAndDedupesFilename() throws {
        let root = try makeTemporaryDirectory()
        let posts = root.appendingPathComponent("posts", isDirectory: true)
        let assets = posts.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let currentFile = posts.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        try Data([0]).write(to: assets.appendingPathComponent("hero.png"))

        let outside = try makeTemporaryDirectory()
        let image = outside.appendingPathComponent("hero.png")
        try Data([1, 2, 3]).write(to: image)

        let paths = try WorkspaceImageAssetStore().place(
            [.file(image)],
            rootURL: root,
            currentFileURL: currentFile
        )

        XCTAssertEqual(paths, ["assets/hero-1.png"])
        XCTAssertEqual(
            try Data(contentsOf: assets.appendingPathComponent("hero-1.png")),
            Data([1, 2, 3])
        )
        XCTAssertEqual(
            try Data(contentsOf: assets.appendingPathComponent("hero.png")),
            Data([0])
        )
    }

    func testClipboardImageDataWritesIntoAssetsAndDedupesFilename() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        try Data([0]).write(to: assets.appendingPathComponent("image.png"))

        let paths = try WorkspaceImageAssetStore().place(
            [.data(Data([9, 8, 7]), suggestedFilename: "../image.png")],
            rootURL: root,
            currentFileURL: currentFile
        )

        XCTAssertEqual(paths, ["assets/image-1.png"])
        XCTAssertEqual(
            try Data(contentsOf: assets.appendingPathComponent("image-1.png")),
            Data([9, 8, 7])
        )
    }

    func testRejectsCurrentFileOutsideWorkspaceRoot() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory().appendingPathComponent("post.md")
        try "Body".write(to: outside, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try WorkspaceImageAssetStore().place(
            [.data(Data([1]), suggestedFilename: "image.png")],
            rootURL: root,
            currentFileURL: outside
        )) { error in
            XCTAssertEqual(
                error as? WorkspaceImageAssetStoreError,
                .currentFileOutsideWorkspace(outside.standardizedFileURL)
            )
        }
    }

    func testRejectsAssetFolderThatEscapesWorkspaceRoot() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try WorkspaceImageAssetStore(assetFolderRelativePath: "../assets").place(
            [.data(Data([1]), suggestedFilename: "image.png")],
            rootURL: root,
            currentFileURL: currentFile
        )) { error in
            XCTAssertEqual(
                error as? WorkspaceImageAssetStoreError,
                .assetFolderEscapesWorkspace("../assets")
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceImageAssetStoreTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
