import Foundation
@testable import PreviewKit
import XCTest

/// The raster read shares the SVG read's bounds: it never blocks on a special file,
/// does not follow a link at the resolved path, and reads no more than the cap.
final class RasterAssetBoundedReadTests: XCTestCase {
    private static let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    func testRegularRasterFileIsReadWhole() throws {
        let file = try makeRoot().appendingPathComponent("image.png")
        try Self.bytes.write(to: file)

        let asset = try AssetURLPolicy.loadAsset(at: file)

        XCTAssertEqual(asset.data, Self.bytes)
        XCTAssertEqual(asset.mimeType, "image/png")
    }

    func testFIFONamedAsARasterDoesNotBlockTheRead() throws {
        let fifo = try makeRoot().appendingPathComponent("fifo.png")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let started = Date()
        XCTAssertThrowsError(try AssetURLPolicy.loadAsset(at: fifo)) {
            XCTAssertEqual($0 as? AssetURLPolicyError, .unsupportedType("png"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "opening a FIFO must not wait for a writer")
    }

    func testDirectoryNamedAsARasterIsRejected() throws {
        let directory = try makeRoot().appendingPathComponent("folder.png", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        XCTAssertThrowsError(try AssetURLPolicy.loadAsset(at: directory)) {
            XCTAssertEqual($0 as? AssetURLPolicyError, .unsupportedType("png"))
        }
    }

    func testLinkAtTheResolvedPathIsNotFollowed() throws {
        let root = try makeRoot()
        let regular = root.appendingPathComponent("image.png")
        try Self.bytes.write(to: regular)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)

        XCTAssertThrowsError(try AssetURLPolicy.loadAsset(at: link)) {
            XCTAssertNil($0 as? AssetURLPolicyError)
        }
    }

    func testMissingRasterFileStillFailsTheRead() throws {
        let missing = try makeRoot().appendingPathComponent("missing.png")

        XCTAssertThrowsError(try AssetURLPolicy.loadAsset(at: missing)) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadNoSuchFile)
        }
    }

    func testDirectReaderMapsASpecialFileToUnsupportedType() async throws {
        let root = try makeRoot()
        let fifo = root.appendingPathComponent("fifo.png")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let access = PreviewAssetTestSupport.access(root: root, generation: 1)
        let request = PreviewAssetReadRequest(
            requestID: UUID(),
            resolvedURL: fifo,
            access: access,
            maximumByteCount: Int(AssetURLPolicy.maxAssetBytes)
        )

        do {
            _ = try await DirectPreviewAssetReader().read(request)
            XCTFail("a FIFO must not be read")
        } catch {
            XCTAssertEqual(error as? PreviewAssetReadFailure, .unsupportedType)
        }
    }

    private func makeRoot() throws -> URL {
        let root = try PreviewAssetTestSupport.directory().resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
