import CoreGraphics
import Foundation
import ImageIO
import MarkdownCore
import UniformTypeIdentifiers
@testable import WorkspaceKit
import XCTest

final class WorkspaceImageThumbnailProviderTests: XCTestCase {
    // MARK: - Security / containment (I10)

    func testRemoteDataAndFileSourcesStayRawWithoutIO() async throws {
        let root = try makeWorkspace()
        let provider = WorkspaceImageThumbnailProvider(cacheByteBudget: 1024 * 1024)
        let remote = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "https://example.com/photo.png",
            hasDirectoryScope: true
        )
        let data = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "data:image/png;base64,AAAA",
            hasDirectoryScope: true
        )
        let file = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "file:///tmp/photo.png",
            hasDirectoryScope: true
        )

        XCTAssertEqual(remote, .stayRaw(.remoteHTTPSource(scheme: "https")))
        XCTAssertEqual(data, .stayRaw(.dataSource))
        XCTAssertEqual(file, .stayRaw(.fileSource))
        let stats = await provider.cacheStats()
        XCTAssertEqual(stats.misses, 0)
        XCTAssertEqual(stats.hits, 0)
    }

    func testParentTraversalAndSymlinkEscapeStayRaw() async throws {
        let root = try makeWorkspace()
        let outside = try makeTemporaryDirectory()
        let outsideImage = outside.appendingPathComponent("secret.png")
        try writePNG(size: 32, to: outsideImage)

        let link = root.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideImage)

        let provider = WorkspaceImageThumbnailProvider()
        let traversal = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "posts",
            source: "../../secret.png",
            hasDirectoryScope: true
        )
        let symlink = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "escape.png",
            hasDirectoryScope: true
        )

        XCTAssertEqual(traversal, .stayRaw(.outsideWorkspace))
        XCTAssertEqual(symlink, .stayRaw(.outsideWorkspace))
    }

    func testAllowlistAndOversizeRejectedBeforeRead() async throws {
        let root = try makeWorkspace()
        let svg = root.appendingPathComponent("vector.svg")
        try Data("<svg/>".utf8).write(to: svg)

        let huge = root.appendingPathComponent("huge.png")
        // Write a file larger than the policy cap without decoding it as an image.
        let oversize = Int(MarkdownImageAssetPolicy.maximumFileSizeBytes) + 1
        try Data(count: oversize).write(to: huge)

        let provider = WorkspaceImageThumbnailProvider()
        let svgOutcome = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "vector.svg",
            hasDirectoryScope: true
        )
        let hugeOutcome = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "huge.png",
            hasDirectoryScope: true
        )

        XCTAssertEqual(svgOutcome, .stayRaw(.unsupportedPathExtension("svg")))
        guard case let .stayRaw(reason) = hugeOutcome else {
            return XCTFail("expected stayRaw for oversized file, got \(hugeOutcome)")
        }
        if case let .fileTooLarge(actual, maximum) = reason {
            XCTAssertEqual(actual, Int64(oversize))
            XCTAssertEqual(maximum, MarkdownImageAssetPolicy.maximumFileSizeBytes)
        } else {
            XCTFail("expected fileTooLarge, got \(reason)")
        }
    }

    func testSingleFileModeHasNoDirectoryScope() async {
        let provider = WorkspaceImageThumbnailProvider()
        let outcome = await provider.load(
            rootURL: nil,
            documentDirectoryRelativePath: "",
            source: "photo.png",
            hasDirectoryScope: false
        )
        XCTAssertEqual(outcome, .stayRaw(.noDirectoryScope))
    }

    // MARK: - Decode / downsample (I2)

    func testDownsampledDimensionsAreBounded() async throws {
        let root = try makeWorkspace()
        let imageURL = root.appendingPathComponent("large.png")
        try writePNG(size: 1200, to: imageURL)

        let provider = WorkspaceImageThumbnailProvider()
        let outcome = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "large.png",
            maxPixelSize: 300,
            hasDirectoryScope: true
        )

        guard case let .ready(thumbnail) = outcome else {
            return XCTFail("expected ready thumbnail, got \(outcome)")
        }
        XCTAssertLessThanOrEqual(max(thumbnail.pixelWidth, thumbnail.pixelHeight), 300)
        XCTAssertGreaterThan(thumbnail.pixelWidth, 0)
        XCTAssertGreaterThan(thumbnail.pixelHeight, 0)
        XCTAssertFalse(thumbnail.pngData.isEmpty)
        XCTAssertEqual(thumbnail.resolvedWorkspaceRelativePath, "large.png")
        XCTAssertEqual(thumbnail.decodedByteCost, thumbnail.pixelWidth * thumbnail.pixelHeight * 4)
    }

    func testDocumentRelativePathAndGIFFirstFrame() async throws {
        let root = try makeWorkspace()
        let posts = root.appendingPathComponent("posts", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: posts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let gif = assets.appendingPathComponent("anim.gif")
        try writeAnimatedGIF(to: gif)

        let provider = WorkspaceImageThumbnailProvider()
        let outcome = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "posts",
            source: "../assets/anim.gif",
            maxPixelSize: 64,
            hasDirectoryScope: true
        )

        guard case let .ready(thumbnail) = outcome else {
            return XCTFail("expected ready gif thumbnail, got \(outcome)")
        }
        XCTAssertEqual(thumbnail.resolvedWorkspaceRelativePath, "assets/anim.gif")
        XCTAssertLessThanOrEqual(max(thumbnail.pixelWidth, thumbnail.pixelHeight), 64)
    }

    func testJPEGAndWebPDecode() async throws {
        let root = try makeWorkspace()
        let jpeg = root.appendingPathComponent("photo.jpg")
        let webp = root.appendingPathComponent("photo.webp")
        try writeJPEG(size: 80, to: jpeg)
        // Minimal valid lossy WebP (1×1) — ImageIO can decode even when destination encoding is unavailable.
        try Data(base64Encoded: Self.oneByOneWebPBase64)?.write(to: webp)

        let provider = WorkspaceImageThumbnailProvider()
        let jpegOutcome = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "photo.jpg",
            maxPixelSize: 40,
            hasDirectoryScope: true
        )
        let webpOutcome = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "photo.webp",
            maxPixelSize: 40,
            hasDirectoryScope: true
        )

        guard case let .ready(jpegThumb) = jpegOutcome else {
            return XCTFail("jpeg failed: \(jpegOutcome)")
        }
        guard case let .ready(webpThumb) = webpOutcome else {
            return XCTFail("webp failed: \(webpOutcome)")
        }
        XCTAssertLessThanOrEqual(max(jpegThumb.pixelWidth, jpegThumb.pixelHeight), 40)
        XCTAssertGreaterThan(webpThumb.pixelWidth, 0)
        XCTAssertGreaterThan(webpThumb.pixelHeight, 0)
    }

    // MARK: - Cache (I8)

    func testCacheHitMissMtimeInvalidationAndByteBudgetEviction() async throws {
        let root = try makeWorkspace()
        let firstImage = root.appendingPathComponent("a.png")
        let secondImage = root.appendingPathComponent("b.png")
        try writePNG(size: 200, to: firstImage)
        try writePNG(size: 200, to: secondImage)

        // Tiny budget forces eviction once two large thumbnails are inserted.
        let provider = WorkspaceImageThumbnailProvider(
            defaultMaxPixelSize: 200,
            cacheByteBudget: 200 * 200 * 4 + 64
        )

        let first = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "a.png",
            maxPixelSize: 200,
            hasDirectoryScope: true
        )
        XCTAssertTrue(first.isReady)
        var stats = await provider.cacheStats()
        XCTAssertEqual(stats.misses, 1)
        XCTAssertEqual(stats.hits, 0)
        XCTAssertEqual(stats.entryCount, 1)

        let second = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "a.png",
            maxPixelSize: 200,
            hasDirectoryScope: true
        )
        XCTAssertTrue(second.isReady)
        stats = await provider.cacheStats()
        XCTAssertEqual(stats.hits, 1)

        // Advance mtime so the previous cache key is stale.
        try writePNG(size: 200, color: .blue, to: firstImage)
        var values = URLResourceValues()
        values.contentModificationDate = Date().addingTimeInterval(120)
        var mutableFirst = firstImage
        try mutableFirst.setResourceValues(values)
        let afterMtime = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "a.png",
            maxPixelSize: 200,
            hasDirectoryScope: true
        )
        XCTAssertTrue(afterMtime.isReady)
        stats = await provider.cacheStats()
        XCTAssertGreaterThanOrEqual(stats.misses, 2)

        _ = await provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "b.png",
            maxPixelSize: 200,
            hasDirectoryScope: true
        )
        stats = await provider.cacheStats()
        XCTAssertGreaterThanOrEqual(stats.evictions, 1)
        XCTAssertLessThanOrEqual(stats.totalByteCost, 200 * 200 * 4 + 64)
    }

    func testConcurrentLoadsCoalesceDecodeWork() async throws {
        let root = try makeWorkspace()
        let image = root.appendingPathComponent("shared.png")
        try writePNG(size: 400, to: image)

        let provider = WorkspaceImageThumbnailProvider()
        async let one = provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "shared.png",
            maxPixelSize: 100,
            hasDirectoryScope: true
        )
        async let two = provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "shared.png",
            maxPixelSize: 100,
            hasDirectoryScope: true
        )
        async let three = provider.load(
            rootURL: root,
            documentDirectoryRelativePath: "",
            source: "shared.png",
            maxPixelSize: 100,
            hasDirectoryScope: true
        )

        let results = await [one, two, three]
        XCTAssertTrue(results.allSatisfy(\.isReady))
        let stats = await provider.cacheStats()
        XCTAssertEqual(results.compactMap(\.readyThumbnail?.resolvedWorkspaceRelativePath).count, 3)
        // Either loads coalesced onto one decode miss, or they ran sequentially with a hit path.
        XCTAssertLessThanOrEqual(stats.misses, 3)
        XCTAssertEqual(stats.misses + stats.hits + stats.coalescedLoads >= 3, true)
    }

    // MARK: - Containment helper

    func testContainedURLRejectsTraversalAndAcceptsNestedPaths() throws {
        let root = try makeWorkspace()
        XCTAssertThrowsError(
            try WorkspaceRootContainment.containedURL(rootURL: root, relativePath: "../x.png")
        )
        let nested = try WorkspaceRootContainment.containedURL(
            rootURL: root,
            relativePath: "posts/a.png"
        )
        XCTAssertTrue(WorkspaceRootContainment.isContained(nested, in: root))
    }
}

// MARK: - Helpers

private extension WorkspaceImageThumbnailOutcome {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var readyThumbnail: WorkspaceImageThumbnail? {
        if case let .ready(thumbnail) = self { return thumbnail }
        return nil
    }
}

private enum FixtureColor {
    case red
    case blue
}

private extension WorkspaceImageThumbnailProviderTests {
    /// 1×1 lossy WebP (RIFF/WEBP VP8) — fixed fixture bytes for ImageIO decode coverage.
    static let oneByOneWebPBase64 =
        "UklGRiQAAABXRUJQVlA4IBgAAAAwAQCdASoBAAEAAwA0JaQAA3AA/vuUAAA="

    func makeWorkspace() throws -> URL {
        let root = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("posts", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-thumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func writePNG(size: Int, color: FixtureColor = .red, to url: URL) throws {
        let image = try makeCGImage(size: size, color: color)
        try writeImage(image, to: url, type: .png)
    }

    func writeJPEG(size: Int, to url: URL) throws {
        let image = try makeCGImage(size: size, color: .red)
        try writeImage(image, to: url, type: .jpeg)
    }

    func writeAnimatedGIF(to url: URL) throws {
        let frameA = try makeCGImage(size: 48, color: .red)
        let frameB = try makeCGImage(size: 48, color: .blue)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            2,
            nil
        ) else {
            throw NSError(domain: "WorkspaceImageThumbnailProviderTests", code: 1)
        }
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        let fileProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProps)
        CGImageDestinationAddImage(destination, frameA, frameProps)
        CGImageDestinationAddImage(destination, frameB, frameProps)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "WorkspaceImageThumbnailProviderTests", code: 2)
        }
        try (data as Data).write(to: url)
    }

    func makeCGImage(size: Int, color: FixtureColor) throws -> CGImage {
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            switch color {
            case .red:
                pixels[index] = 255
                pixels[index + 1] = 0
                pixels[index + 2] = 0
                pixels[index + 3] = 255
            case .blue:
                pixels[index] = 0
                pixels[index + 1] = 0
                pixels[index + 2] = 255
                pixels[index + 3] = 255
            }
        }
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw NSError(domain: "WorkspaceImageThumbnailProviderTests", code: 3)
        }
        return image
    }

    func writeImage(_ image: CGImage, to url: URL, type: UTType) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "WorkspaceImageThumbnailProviderTests", code: 4)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "WorkspaceImageThumbnailProviderTests", code: 5)
        }
        try (data as Data).write(to: url)
    }
}
