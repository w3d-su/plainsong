import CoreGraphics
import Foundation
import ImageIO
import MarkdownCore
@testable import PreviewKit
import UniformTypeIdentifiers
import XCTest

final class ExportResourceResolverTests: XCTestCase {
    func testContainedPNGAtTenMebibyteBoundaryEmbedsAndOneExtraByteIsOmitted() throws {
        let root = try makeRoot()
        let limit = Int(MarkdownImageAssetPolicy.maximumFileSizeBytes)
        let accepted = try writePNG(ExportRasterFixture.png(exactByteCount: limit), name: "exact.png", in: root)
        let rejected = try writePNG(
            Data(repeating: 0, count: limit + 1),
            name: "over.png",
            in: root
        )

        let outcomes = ExportResourceResolver.resolve(
            [image("exact", accepted), image("over", rejected)],
            assetRoot: root,
            previewDirectory: nil
        )

        XCTAssertEqual(outcomes[0].action, .embed)
        XCTAssertTrue(outcomes[0].dataURI?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertEqual(outcomes[1].action, .omit)
        XCTAssertNil(outcomes[1].dataURI)
        XCTAssertEqual(outcomes[1].reason, "too-large")
    }

    func testJPEGGifAndWebPEmbedWithMatchingMIME() throws {
        let root = try makeRoot()
        let webP = try XCTUnwrap(
            Data(base64Encoded: "UklGRiQAAABXRUJQVlA4IBgAAAAwAQCdASoBAAEAAwA0JaQAA3AA/vuUAAA=")
        )
        let samples = try [
            ("photo.jpg", ExportRasterFixture.encoded(.jpeg), "image/jpeg"),
            ("photo.gif", ExportRasterFixture.encoded(.gif), "image/gif"),
            ("photo.webp", webP, "image/webp"),
        ]
        let resources = try samples.map { name, data, _ in
            try image(name, writePNG(data, name: name, in: root))
        }

        let outcomes = ExportResourceResolver.resolve(resources, assetRoot: root, previewDirectory: nil)

        for (outcome, sample) in zip(outcomes, samples) {
            XCTAssertEqual(outcome.action, .embed, sample.0)
            XCTAssertTrue(outcome.dataURI?.hasPrefix("data:\(sample.2);base64,") == true, sample.0)
        }
    }

    func testDistinctRasterBytesStopAtThirtyTwoMebibytesAndOneExtraByteOmits() throws {
        let root = try makeRoot()
        let ten = Int(MarkdownImageAssetPolicy.maximumFileSizeBytes)
        let two = (32 * 1024 * 1024) - (ten * 3)
        var resources: [ExportResourceDescriptor] = []
        for index in 0 ..< 3 {
            let url = try writePNG(ExportRasterFixture.png(exactByteCount: ten), name: "part-\(index).png", in: root)
            resources.append(image("part-\(index)", url))
        }
        let fitting = try writePNG(ExportRasterFixture.png(exactByteCount: two), name: "fit.png", in: root)
        let overflowing = try writePNG(
            ExportRasterFixture.png(exactByteCount: two + 1),
            name: "overflow.png",
            in: root
        )

        let started = Date()
        let residentBefore = ExportRasterFixture.residentBytes()
        let exact = ExportResourceResolver.resolve(
            resources + [image("fit", fitting)],
            assetRoot: root,
            previewDirectory: nil
        )
        let over = ExportResourceResolver.resolve(
            resources + [image("overflow", overflowing)],
            assetRoot: root,
            previewDirectory: nil
        )
        let elapsed = Date().timeIntervalSince(started)
        let residentAfter = ExportRasterFixture.residentBytes()
        print(
            "EXPORT_CAP_FIXTURE elapsed=\(elapsed) residentBefore=\(residentBefore) residentAfter=\(residentAfter)"
        )

        XCTAssertEqual(exact.map(\.action), Array(repeating: .embed, count: 4))
        XCTAssertEqual(over.dropLast().map(\.action), Array(repeating: .embed, count: 3))
        XCTAssertEqual(over.last?.action, .omit)
        XCTAssertEqual(over.last?.reason, ExportResourceResolver.exportImageSizeLimitReason)
        XCTAssertNil(over.last?.dataURI)
    }

    func testRepeatedAssetReferenceCountsDecodedBytesOnce() throws {
        let root = try makeRoot()
        let ten = Int(MarkdownImageAssetPolicy.maximumFileSizeBytes)
        let bytes = ExportRasterFixture.png(exactByteCount: ten)
        let first = try writePNG(bytes, name: "shared.png", in: root)
        let second = try writePNG(bytes, name: "other.png", in: root)
        let third = try writePNG(ExportRasterFixture.png(exactByteCount: ten), name: "third.png", in: root)
        let fourth = try writePNG(
            ExportRasterFixture.png(exactByteCount: (ten / 5) + 1),
            name: "fourth.png",
            in: root
        )

        let outcomes = ExportResourceResolver.resolve(
            [
                image("shared-a", first),
                image("shared-b", first),
                image("other", second),
                image("third", third),
                image("fourth", fourth),
            ],
            assetRoot: root,
            previewDirectory: nil
        )

        XCTAssertEqual(outcomes.map(\.action), [.embed, .embed, .embed, .embed, .omit])
        XCTAssertNotNil(outcomes[0].dataURI)
        XCTAssertNil(outcomes[1].dataURI)
        XCTAssertEqual(outcomes[1].dataURIFrom, "shared-a")
        XCTAssertEqual(outcomes[2].action, .embed)
        XCTAssertNil(outcomes[2].dataURIFrom, "Equal bytes at another path are a distinct asset")
        XCTAssertEqual(outcomes[4].reason, ExportResourceResolver.exportImageSizeLimitReason)
    }

    func testRejectedImagesOmitWithoutEmbedding() throws {
        let root = try makeRoot()
        let outside = try makeRoot(named: "outside")
        let secretURL = outside.appendingPathComponent("secret.png")
        try ExportRasterFixture.encoded(.png).write(to: secretURL)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.png"),
            withDestinationURL: secretURL
        )
        try ExportRasterFixture.encoded(.png).write(to: root.appendingPathComponent("photo.svg"))
        let missing = "asset://missing.png"

        let outcomes = ExportResourceResolver.resolve(
            [
                image("traversal", "asset://../secret.png"),
                image("symlink", "asset://escape.png"),
                image("svg", "asset://photo.svg"),
                image("remote", "https://example.com/photo.png"),
                image("file", secretURL.absoluteString),
                image("missing", missing),
                image("empty", "  "),
            ],
            assetRoot: root,
            previewDirectory: nil
        )

        XCTAssertEqual(
            outcomes.map(\.action),
            Array(repeating: ExportResourceAction.omit, count: outcomes.count)
        )
        XCTAssertTrue(outcomes.allSatisfy { $0.dataURI == nil })
        XCTAssertEqual(outcomes[0].reason, "escapes-root")
        XCTAssertEqual(outcomes[1].reason, "escapes-root")
        XCTAssertEqual(outcomes[3].reason, "rejected-scheme")
        XCTAssertNotEqual(outcomes[0].reason, ExportResourceResolver.exportImageSizeLimitReason)
    }

    func testAuthoredDataImageNormalizesAndRejectsMalformedOrOversize() throws {
        let png = try ExportRasterFixture.encoded(.png)
        let uri = "data:image/png;base64,\(png.base64EncodedString())"
        let spaced = "  DATA:image/png;base64,\(png.base64EncodedString())  "
        let svg = "data:image/svg+xml;base64,\(Data("svg".utf8).base64EncodedString())"
        let oversize = Data(count: Int(MarkdownImageAssetPolicy.maximumFileSizeBytes) + 1)
        let overURI = "data:image/png;base64,\(oversize.base64EncodedString())"
        let mismatched = try "data:image/png;base64,\(ExportRasterFixture.encoded(.jpeg).base64EncodedString())"

        let outcomes = ExportResourceResolver.resolve(
            [
                image("png", uri),
                image("repeat", spaced),
                image("svg", svg),
                image("broken", "data:image/png;base64,@@@"),
                image("over", overURI),
                image("mismatch", mismatched),
            ],
            assetRoot: nil,
            previewDirectory: nil
        )

        XCTAssertEqual(outcomes[0].action, .embed)
        XCTAssertEqual(outcomes[1].action, .embed)
        XCTAssertEqual(outcomes[0].dataURI, uri)
        XCTAssertNil(outcomes[1].dataURI)
        XCTAssertEqual(outcomes[1].dataURIFrom, "png")
        XCTAssertEqual(outcomes[2].action, .omit)
        XCTAssertEqual(outcomes[3].action, .omit)
        XCTAssertEqual(outcomes[4].reason, "malformed-data")
        XCTAssertEqual(outcomes[5].reason, "malformed-data")
        XCTAssertNil(outcomes[4].dataURI)
    }

    func testManifestWoff2EmbedsAndOtherFontPathsOmit() throws {
        let preview = try makeRoot(named: "preview")
        let fonts = preview.appendingPathComponent("fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        let bytes = Data("woff2-fixture".utf8)
        try bytes.write(to: fonts.appendingPathComponent("KaTeX_Main-Regular.woff2"))
        try Data("ttf".utf8).write(to: fonts.appendingPathComponent("KaTeX_Main-Regular.ttf"))
        let manifest = """
        {"format":"woff2","files":["KaTeX_Main-Regular.woff2","Secret.woff2","../secret.woff2"]}
        """
        try manifest.write(to: preview.appendingPathComponent("font-manifest.json"), atomically: true, encoding: .utf8)
        let outside = try makeRoot(named: "font-outside")
        try Data("secret".utf8).write(to: outside.appendingPathComponent("Secret.woff2"))
        try FileManager.default.createSymbolicLink(
            at: fonts.appendingPathComponent("Secret.woff2"),
            withDestinationURL: outside.appendingPathComponent("Secret.woff2")
        )

        let outcomes = ExportResourceResolver.resolve(
            [
                font("woff2", "fonts/KaTeX_Main-Regular.woff2"),
                font("ttf", "fonts/KaTeX_Main-Regular.ttf"),
                font("user", "/Library/Fonts/Arial.woff2"),
                font("escape", "fonts/../../secret.woff2"),
                font("link", "fonts/Secret.woff2"),
            ],
            assetRoot: nil,
            previewDirectory: preview
        )

        XCTAssertEqual(outcomes[0].action, .embed)
        XCTAssertEqual(
            outcomes[0].dataURI,
            "data:font/woff2;base64,\(bytes.base64EncodedString())"
        )
        XCTAssertEqual(outcomes.dropFirst().map(\.action), Array(repeating: .omit, count: 4))
        XCTAssertTrue(outcomes.dropFirst().allSatisfy { $0.dataURI == nil })
    }

    private func makeRoot(named name: String = "assets") throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plainsong-export-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        return root
    }

    private func writePNG(_ data: Data, name: String, in root: URL) throws -> String {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return "asset://\(name)"
    }

    private func image(_ name: String, _ source: String) -> ExportResourceDescriptor {
        ExportResourceDescriptor(resourceID: name, kind: .image, src: source)
    }

    private func font(_ name: String, _ source: String) -> ExportResourceDescriptor {
        ExportResourceDescriptor(resourceID: name, kind: .font, src: source)
    }
}

enum ExportRasterFixture {
    static func png(exactByteCount: Int) -> Data {
        let base = tryEncode(.png)
        precondition(exactByteCount >= base.count)
        let extra = exactByteCount - base.count
        guard extra > 0 else {
            return base
        }
        precondition(extra >= 14)
        var text = Data([0x41, 0x00])
        text.append(Data(repeating: 0x20, count: extra - 14))
        var padded = base
        let ending = padded.suffix(12)
        padded.removeLast(12)
        padded.append(pngChunk(type: "tEXt", data: text))
        padded.append(ending)
        precondition(padded.count == exactByteCount)
        return padded
    }

    static func encoded(_ type: UTType) throws -> Data {
        let data = tryEncode(type)
        if data.isEmpty {
            throw NSError(domain: "ExportRasterFixture", code: 1)
        }
        return data
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / 4)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private static func tryEncode(_ type: UTType) -> Data {
        let image = tinyImage()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return Data()
        }
        return data as Data
    }

    private static func tinyImage() -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }

    private static func pngChunk(type: String, data: Data) -> Data {
        var chunk = Data()
        var length = UInt32(data.count).bigEndian
        chunk.append(Data(bytes: &length, count: 4))
        let typeData = Data(type.utf8)
        chunk.append(typeData)
        chunk.append(data)
        var checksum = pngCRC(typeData + data).bigEndian
        chunk.append(Data(bytes: &checksum, count: 4))
        return chunk
    }

    private static func pngCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                let mask: UInt32 = (crc & 1) == 1 ? 0xEDB8_8320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
