import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

final class ExportLeasedResourceResolverTests: XCTestCase {
    func testReaderPayloadRetentionStaysWithinBudgetWithOneReadAllowance() async throws {
        let access = try makeAccess()
        let byteCount = Int(MarkdownImageAssetPolicy.maximumFileSizeBytes)
        let allocations = ExportPayloadAllocations()
        let reader = AllocatingExportReader(
            templates: ["large": ExportRasterFixture.png(exactByteCount: byteCount)],
            allocations: allocations
        )
        let resources = (0 ..< 8).map { image("large-\($0)", "asset://large-\($0).png") }

        let outcomes = await resolve(
            resources, access: access, previewDirectory: nil, reader: reader
        )

        XCTAssertEqual(outcomes.map(\.resourceID), resources.map(\.resourceID))
        XCTAssertEqual(outcomes.map(\.action), [.embed, .embed, .embed] + Array(repeating: .omit, count: 5))
        XCTAssertTrue(outcomes.dropFirst(3).allSatisfy {
            $0.reason == ExportResourceResolver.exportImageSizeLimitReason && $0.dataURI == nil
        })
        let usage = allocations.snapshot
        let allowance = Int(ExportResourceResolver.maximumDistinctDecodedRasterBytes) + byteCount
        print("LEASED_EXPORT_MEMORY peakPayloadBytes=\(usage.peak) allowance=\(allowance) reads=\(usage.count)")
        XCTAssertEqual(usage.count, 8)
        XCTAssertLessThanOrEqual(usage.peak, allowance)
        XCTAssertEqual(usage.live, 0, "Outcomes must not retain the reader's raw payloads")
    }

    func testMixedImagesShareDocumentOrderBudgetAndLaterSmallImageStillFits() async throws {
        let access = try makeAccess()
        let mebibyte = 1024 * 1024
        let large = ExportRasterFixture.png(exactByteCount: 10 * mebibyte)
        let authored = "data:image/png;base64,\(large.base64EncodedString())"
        let allocations = ExportPayloadAllocations()
        let reader = AllocatingExportReader(
            templates: [
                "large": large,
                "overflow": ExportRasterFixture.png(exactByteCount: 3 * mebibyte),
                "small": ExportRasterFixture.png(exactByteCount: 2 * mebibyte),
            ],
            allocations: allocations
        )
        let outcomes = await resolve(
            [
                image("authored", authored),
                image("first", "asset://large-1.png"),
                image("second", "asset://large-2.png"),
                image("overflow", "asset://overflow.png"),
                image("small", "asset://small.png"),
                image("first-repeat", "asset://large-1.png"),
                image("overflow-repeat", "asset://overflow.png"),
                image("authored-repeat", authored),
            ],
            access: access,
            previewDirectory: nil,
            reader: reader
        )

        XCTAssertEqual(outcomes.map(\.action), [.embed, .embed, .embed, .omit, .embed, .embed, .omit, .embed])
        XCTAssertEqual(outcomes[3].reason, ExportResourceResolver.exportImageSizeLimitReason)
        XCTAssertNotNil(outcomes[4].dataURI)
        XCTAssertNil(outcomes[5].dataURI)
        XCTAssertEqual(outcomes[5].dataURIFrom, "first")
        XCTAssertEqual(outcomes[6].reason, outcomes[3].reason)
        XCTAssertEqual(outcomes[7].dataURIFrom, "authored")
        let names = await reader.names
        XCTAssertEqual(names, ["large-1.png", "large-2.png", "overflow.png", "small.png"])
        XCTAssertEqual(allocations.snapshot.live, 0)
    }

    func testCancelledReadDoesNotEmbedOrStartAnotherRead() async throws {
        let access = try makeAccess()
        let reader = try PausedExportReader(png: ExportRasterFixture.encoded(.png))
        let resources = [image("first", "asset://first.png"), image("second", "asset://second.png")]
        let task = Task {
            await resolve(
                resources, access: access, previewDirectory: nil, reader: reader
            )
        }
        await reader.waitForRead()
        task.cancel()
        await reader.finishRead()
        let outcomes = await task.value

        XCTAssertEqual(outcomes.map(\.action), [.omit, .omit])
        XCTAssertEqual(outcomes.map(\.reason), ["cancelled", "cancelled"])
        let names = await reader.names
        XCTAssertEqual(names, ["first.png"])
    }

    func testRejectedPayloadDoesNotConsumeBudgetOrGetReadAgain() async throws {
        let access = try makeAccess()
        let mebibyte = 1024 * 1024
        let allocations = ExportPayloadAllocations()
        let reader = AllocatingExportReader(
            templates: [
                "invalid": Data(repeating: 0, count: 10 * mebibyte),
                "large": ExportRasterFixture.png(exactByteCount: 10 * mebibyte),
                "small": ExportRasterFixture.png(exactByteCount: 2 * mebibyte),
            ],
            allocations: allocations
        )
        let outcomes = await resolve(
            [
                image("invalid", "asset://invalid.png"),
                image("first", "asset://large-1.png"),
                image("second", "asset://large-2.png"),
                image("third", "asset://large-3.png"),
                image("small", "asset://small.png"),
                image("invalid-repeat", "asset://invalid.png"),
            ],
            access: access, previewDirectory: nil, reader: reader
        )

        XCTAssertEqual(outcomes.map(\.action), [.omit, .embed, .embed, .embed, .embed, .omit])
        XCTAssertEqual(outcomes.first?.reason, "unsupported")
        XCTAssertEqual(outcomes.last?.reason, "unsupported")
        let names = await reader.names
        XCTAssertEqual(names, ["invalid.png", "large-1.png", "large-2.png", "large-3.png", "small.png"])
        XCTAssertEqual(allocations.snapshot.live, 0)
    }

    private func resolve(
        _ resources: [ExportResourceDescriptor],
        access: PreviewAssetAccessContext,
        previewDirectory: URL?,
        reader: any PreviewAssetReading
    ) async -> [ExportResourceOutcome] {
        await ExportResourceResolver.resolve(
            resources,
            assetRoot: access.allowedRoot,
            previewDirectory: previewDirectory,
            loadAsset: PreviewController.exportAssetLoader(reader: reader, access: access)
        )
    }

    private func makeAccess() throws -> PreviewAssetAccessContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-leased-export-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return PreviewAssetAccessContext(
            allowedRoot: root, rootToken: UUID(), grantIdentity: UUID(), accessGeneration: 1
        )
    }

    private func image(_ identifier: String, _ source: String) -> ExportResourceDescriptor {
        ExportResourceDescriptor(resourceID: identifier, kind: .image, src: source)
    }
}

private final class ExportPayloadAllocations: @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    private var peak = 0
    private var count = 0

    var snapshot: (live: Int, peak: Int, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (live, peak, count)
    }

    func copy(_ template: Data) -> Data {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: template.count, alignment: 8)
        template.withUnsafeBytes { buffer in
            pointer.copyMemory(from: buffer.baseAddress!, byteCount: template.count)
        }
        lock.lock()
        live += template.count
        peak = max(peak, live)
        count += 1
        lock.unlock()
        return Data(bytesNoCopy: pointer, count: template.count, deallocator: .custom { pointer, count in
            self.release(count)
            pointer.deallocate()
        })
    }

    private func release(_ byteCount: Int) {
        lock.lock()
        live -= byteCount
        lock.unlock()
    }
}

private actor AllocatingExportReader: PreviewAssetReading {
    let templates: [String: Data]
    let allocations: ExportPayloadAllocations
    private(set) var names: [String] = []

    init(templates: [String: Data], allocations: ExportPayloadAllocations) {
        self.templates = templates
        self.allocations = allocations
    }

    func read(_ request: PreviewAssetReadRequest) async throws -> PreviewAssetReadResult {
        let name = request.resolvedURL.lastPathComponent
        names.append(name)
        let key = String(name.split(separator: "-").first ?? "").replacingOccurrences(of: ".png", with: "")
        let template = try XCTUnwrap(templates[key])
        return PreviewAssetReadResult(
            requestID: request.requestID, coordinatedURL: request.resolvedURL,
            bytes: allocations.copy(template), access: request.access
        )
    }
}

private actor PausedExportReader: PreviewAssetReading {
    let png: Data
    private(set) var names: [String] = []
    private var readStarted: CheckedContinuation<Void, Never>?
    private var readFinished: CheckedContinuation<Void, Never>?

    init(png: Data) {
        self.png = png
    }

    func read(_ request: PreviewAssetReadRequest) async throws -> PreviewAssetReadResult {
        names.append(request.resolvedURL.lastPathComponent)
        await withCheckedContinuation { continuation in
            readFinished = continuation
            readStarted?.resume()
            readStarted = nil
        }
        return PreviewAssetReadResult(
            requestID: request.requestID, coordinatedURL: request.resolvedURL,
            bytes: png, access: request.access
        )
    }

    func waitForRead() async {
        guard names.isEmpty else { return }
        await withCheckedContinuation { readStarted = $0 }
    }

    func finishRead() {
        readFinished?.resume()
        readFinished = nil
    }
}
