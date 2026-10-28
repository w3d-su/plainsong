import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

/// PR #229 review: fail-closed headers, one SVG decision per read, the rejection
/// reason, and the bounded regular-file read.
@MainActor
final class SVGAssetDeliveryTests: XCTestCase {
    private static let svg = Data(
        #"<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2"/></svg>"#.utf8
    )

    func testAdmittedSVGFailsClosedWhenItsHeadersCannotBeBuilt() throws {
        let asset = try AssetURLPolicy.deliveredPreviewAsset(
            data: Self.svg,
            fileURL: URL(fileURLWithPath: "/tmp/mark.svg")
        )
        let url = try XCTUnwrap(URL(string: "asset://mark.svg"))
        XCTAssertNil(AssetDeliveryResponse.make(url: url, asset: asset, httpResponse: { _, _ in nil }))

        let raster = AssetURLPolicyResult(mimeType: "image/png", data: PreviewAssetTestSupport.onePixelPNG)
        let rasterResponse = AssetDeliveryResponse.make(url: url, asset: raster, httpResponse: { _, _ in nil })
        XCTAssertEqual(rasterResponse?.mimeType, "image/png")
        XCTAssertFalse(rasterResponse is HTTPURLResponse)
    }

    func testRejectionKeepsTheValidatorReason() {
        XCTAssertThrowsError(try AssetURLPolicy.deliveredPreviewAsset(
            data: Data(#"<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>"#.utf8),
            fileURL: URL(fileURLWithPath: "/tmp/a.svg")
        )) { error in
            XCTAssertEqual(error as? AssetURLPolicyError, .rejectedSVG(.forbiddenElement("script")))
        }
    }

    func testReaderMustReturnTheSameKindOfFileItWasAskedFor() async throws {
        let root = try makeRoot()
        for (requested, coordinated, bytes) in [
            ("mark.svg", "mark.png", Self.svg),
            ("pixel.png", "pixel.svg", PreviewAssetTestSupport.onePixelPNG),
        ] {
            let handler = AssetURLSchemeHandler()
            let reader = GatePreviewAssetReader()
            handler.installReader(reader)
            var failures: [PreviewAssetReadFailure] = []
            handler.onCurrentFailure = { failures.append($0) }
            let token = handler.updateAuthority(PreviewAssetTestSupport.access(root: root, generation: 1)).token
            let task = RecordingSchemeTask(url: PreviewAssetTestSupport.assetURL(token: token, path: requested))
            handler.start(task)
            await PreviewAssetTestSupport.waitUntil("read \(requested)") { reader.hasWaiter() }
            let terminal = expectation(description: requested)
            task.onTerminal = { terminal.fulfill() }
            reader.resumeFirst(bytes: bytes, coordinatedURL: root.appendingPathComponent(coordinated))
            await fulfillment(of: [terminal], timeout: 2)
            XCTAssertEqual(task.failures, 1, requested)
            XCTAssertEqual(task.responseCount, 0, requested)
            XCTAssertTrue(task.data.isEmpty, requested)
            XCTAssertEqual(failures, [.unsupportedType], requested)
        }
        XCTAssertThrowsError(try AssetFilesystemPreparation.containedAsset(
            Self.svg,
            fileURL: root.appendingPathComponent("a.png"),
            requestedURL: root.appendingPathComponent("a.svg"),
            root: root
        )) { error in
            XCTAssertEqual(error as? AssetURLPolicyError, .kindChangedDuringRead)
        }
    }

    func testDirectSVGReadIsBoundedAndRegularFileOnly() throws {
        let root = try makeRoot()
        let regular = root.appendingPathComponent("mark.svg")
        try Self.svg.write(to: regular)
        XCTAssertEqual(try DirectPreviewAssetReader.svgBytes(at: regular, maximumByteCount: Self.svg.count), Self.svg)
        XCTAssertThrowsError(try DirectPreviewAssetReader.svgBytes(at: regular, maximumByteCount: Self.svg.count - 1)) {
            XCTAssertEqual($0 as? PreviewAssetReadFailure, .tooLarge)
        }

        let fifo = root.appendingPathComponent("fifo.svg")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertThrowsError(try DirectPreviewAssetReader.svgBytes(at: fifo, maximumByteCount: 1024)) {
            XCTAssertEqual($0 as? PreviewAssetReadFailure, .unsupportedType)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "opening a FIFO must not wait for a writer")

        let directory = root.appendingPathComponent("folder.svg", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try DirectPreviewAssetReader.svgBytes(at: directory, maximumByteCount: 1024)) {
            XCTAssertEqual($0 as? PreviewAssetReadFailure, .unsupportedType)
        }

        let link = root.appendingPathComponent("link.svg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        XCTAssertThrowsError(try DirectPreviewAssetReader.svgBytes(at: link, maximumByteCount: 1024)) {
            XCTAssertEqual($0 as? PreviewAssetReadFailure, .providerFailed)
        }
    }

    private func makeRoot() throws -> URL {
        let root = try PreviewAssetTestSupport.directory().resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
