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

    func testOutsideWorkspaceImageCopiesThroughFileCopyOperation() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)

        let outside = try makeTemporaryDirectory()
        let image = outside.appendingPathComponent("hero.webp")
        let imageData = Data([1, 2, 3])
        try imageData.write(to: image)

        let recorder = CopyRecorder()
        let paths = try WorkspaceImageAssetStore(copyFile: { sourceURL, destinationURL in
            try recorder.copyFile(from: sourceURL, to: destinationURL)
        }).place(
            [.file(image)],
            rootURL: root,
            currentFileURL: currentFile
        )

        XCTAssertEqual(paths, ["assets/hero.webp"])
        XCTAssertEqual(recorder.copiedSourceURLs, [image.standardizedFileURL.resolvingSymlinksInPath()])
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("assets/hero.webp")),
            imageData
        )
    }

    func testSymlinkInsideWorkspacePointingOutsideCopiesRealFileIntoAssets() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)

        let outside = try makeTemporaryDirectory()
        let outsideImage = outside.appendingPathComponent("secret.png")
        let imageData = Data([4, 5, 6])
        try imageData.write(to: outsideImage)

        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideImage)

        let paths = try WorkspaceImageAssetStore().place(
            [.file(link)],
            rootURL: root,
            currentFileURL: currentFile
        )

        XCTAssertEqual(paths, ["assets/secret.png"])
        XCTAssertFalse(paths[0].split(separator: "/").contains(".."))

        let copiedImage = root.appendingPathComponent(paths[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedImage.path(percentEncoded: false)))
        XCTAssertEqual(try Data(contentsOf: copiedImage), imageData)
        XCTAssertFalse(
            try copiedImage.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false
        )
        XCTAssertNotEqual(
            copiedImage.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false),
            outsideImage.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        )

        var rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while rootPath.count > 1, rootPath.hasSuffix("/") {
            rootPath.removeLast()
        }
        let copiedPath = copiedImage.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        XCTAssertTrue(copiedPath == rootPath || copiedPath.hasPrefix("\(rootPath)/"))
    }

    func testRejectsUnsupportedFileImageTypesBeforeCopying() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)

        let outside = try makeTemporaryDirectory()
        let unsupportedFilenames = [
            "vector.svg",
            "scan.tiff",
            "bitmap.bmp",
            "notes.txt",
            "unknown",
        ]

        for filename in unsupportedFilenames {
            let file = outside.appendingPathComponent(filename)
            try Data([1, 2, 3]).write(to: file)

            XCTAssertThrowsError(try WorkspaceImageAssetStore(copyFile: failIfCopyFileIsCalled).place(
                [.file(file)],
                rootURL: root,
                currentFileURL: currentFile
            )) { error in
                XCTAssertEqual(error as? WorkspaceImageAssetStoreError, .unsupportedImageType(filename))
            }
        }
    }

    func testRejectsOversizedFileImageBeforeCopying() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)

        let outside = try makeTemporaryDirectory()
        let image = outside.appendingPathComponent("huge.png")
        try createSparseFile(
            at: image,
            byteCount: UInt64(WorkspaceImageAssetStore.defaultMaximumImportedImageSizeBytes + 1)
        )

        XCTAssertThrowsError(try WorkspaceImageAssetStore(copyFile: failIfCopyFileIsCalled).place(
            [.file(image)],
            rootURL: root,
            currentFileURL: currentFile
        )) { error in
            XCTAssertEqual(
                error as? WorkspaceImageAssetStoreError,
                .importedImageTooLarge(
                    "huge.png",
                    maximumBytes: WorkspaceImageAssetStore.defaultMaximumImportedImageSizeBytes
                )
            )
        }
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

    func testRejectsClipboardImageDataWithUnsupportedSuggestedType() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try WorkspaceImageAssetStore().place(
            [.data(Data([1, 2, 3]), suggestedFilename: "vector.svg")],
            rootURL: root,
            currentFileURL: currentFile
        )) { error in
            XCTAssertEqual(error as? WorkspaceImageAssetStoreError, .unsupportedImageType("vector.svg"))
        }
    }

    func testRejectsOversizedClipboardImageData() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try WorkspaceImageAssetStore().place(
            [
                .data(
                    Data(count: Int(WorkspaceImageAssetStore.defaultMaximumImportedImageSizeBytes + 1)),
                    suggestedFilename: "huge.png"
                ),
            ],
            rootURL: root,
            currentFileURL: currentFile
        )) { error in
            XCTAssertEqual(
                error as? WorkspaceImageAssetStoreError,
                .importedImageTooLarge(
                    "huge.png",
                    maximumBytes: WorkspaceImageAssetStore.defaultMaximumImportedImageSizeBytes
                )
            )
        }
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

    private func createSparseFile(at url: URL, byteCount: UInt64) throws {
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: byteCount)
        try handle.close()
    }
}

private struct UnexpectedCopyFileCallError: Error {}

private let failIfCopyFileIsCalled: @Sendable (URL, URL) throws -> Void = { _, _ in
    throw UnexpectedCopyFileCallError()
}

private final class CopyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceURLs: [URL] = []

    var copiedSourceURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return sourceURLs
    }

    func copyFile(from sourceURL: URL, to destinationURL: URL) throws {
        lock.lock()
        sourceURLs.append(sourceURL)
        lock.unlock()
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}
