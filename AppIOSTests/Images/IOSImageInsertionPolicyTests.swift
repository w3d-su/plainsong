import CoreGraphics
import ImageIO
import MarkdownCore
@testable import PlainsongIOS
import UniformTypeIdentifiers
import XCTest

@MainActor
final class IOSImageInsertionPolicyTests: XCTestCase {
    func testTenMebibyteBoundary() async throws {
        let normalizer = IOSImagePayloadNormalizer()
        let exact = try normalizer.normalize(
            bytes: ImageBytes.png(count: ImageBytes.limit),
            contentType: "image/png",
            preferredFilename: "edge.png"
        )
        XCTAssertEqual(exact.bytes.count, ImageBytes.limit)
        XCTAssertThrowsError(try normalizer.normalize(
            bytes: ImageBytes.png(count: ImageBytes.limit + 1),
            contentType: "image/png",
            preferredFilename: "over.png"
        )) { error in
            XCTAssertEqual(error as? IOSImageNormalizationError, .tooLarge)
        }

        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        await assertFailed(
            harness.insert(context, bytes: ImageBytes.png(count: ImageBytes.limit + 1), filename: "over.png"),
            .tooLarge
        )
        XCTAssertEqual(harness.writer.calls, [])
        harness.assertSourceUntouched()
    }

    func testOversizeAfterHEICTranscodeIsRejected() async throws {
        let transcoder = RecordingTranscoder(png: ImageBytes.png(count: ImageBytes.limit + 1))
        let harness = ImageInsertionHarness(transcoder: transcoder)
        let context = try harness.capture()
        await assertFailed(
            harness.insert(context, bytes: ImageBytes.heic(), contentType: "image/heic", filename: "Shot.HEIC"),
            .tooLarge
        )
        XCTAssertEqual(harness.writer.calls, [])
        XCTAssertFalse(transcoder.observedMainThread)
        harness.assertSourceUntouched()
    }

    func testHEICConversionStagesPNGBytes() async throws {
        let png = ImageBytes.png
        let transcoder = RecordingTranscoder(png: png)
        let harness = ImageInsertionHarness(transcoder: transcoder)
        let context = try harness.capture()
        _ = await assertInserted(harness.insert(
            context,
            bytes: ImageBytes.heic(),
            contentType: "public.heic",
            filename: "../../Shot.HEIC"
        ))
        let request = try XCTUnwrap(harness.writer.stagedRequests.first)
        XCTAssertEqual(request.bytes, png)
        XCTAssertEqual(request.contentType, "image/png")
        XCTAssertEqual(request.preferredFilename, "Shot.png")
        XCTAssertNotEqual(request.bytes, ImageBytes.heic())
        XCTAssertFalse(transcoder.observedMainThread)
    }

    func testImageIOTranscodesGeneratedHEIC() throws {
        let heic = try makeHEIC()
        let payload = try IOSImagePayloadNormalizer(transcoder: IOSImageIORasterTranscoder()).normalize(
            bytes: heic,
            contentType: "image/heic",
            preferredFilename: "camera.HEIC"
        )
        XCTAssertEqual(payload.contentType, "image/png")
        XCTAssertEqual(payload.preferredFilename, "camera.png")
        XCTAssertEqual(IOSImageByteSignature.sniff(payload.bytes), .raster(.png))
        XCTAssertLessThanOrEqual(Int64(payload.bytes.count), MarkdownImageAssetPolicy.maximumFileSizeBytes)
        XCTAssertFalse(payload.bytes.starts(with: [0x00, 0x00, 0x00]))
    }

    func testAllowedRasters() throws {
        let normalizer = IOSImagePayloadNormalizer()
        let samples: [(Data, String, String, String)] = [
            (ImageBytes.png, "image/png", "a.png", "image/png"),
            (ImageBytes.jpeg, "image/jpeg", "a.jpg", "image/jpeg"),
            (ImageBytes.jpeg, "image/jpeg", "a.jpeg", "image/jpeg"),
            (ImageBytes.gif, "image/gif", "a.gif", "image/gif"),
            (ImageBytes.gif87, "image/gif", "old.gif", "image/gif"),
            (ImageBytes.webp, "image/webp", "a.webp", "image/webp"),
            (ImageBytes.png, "image/png; charset=binary", "A.PNG", "image/png"),
            (ImageBytes.png, "image/png", "folder/leaf.png", "image/png"),
        ]
        for sample in samples {
            let payload = try normalizer.normalize(
                bytes: sample.0,
                contentType: sample.1,
                preferredFilename: sample.2
            )
            XCTAssertEqual(payload.contentType, sample.3)
            let declared = try XCTUnwrap(IOSImageDeclaredType.parse(sample.3).rasterKind)
            XCTAssertEqual(IOSImageByteSignature.sniff(payload.bytes), .raster(declared))
        }
        let leaf = try normalizer.normalize(
            bytes: ImageBytes.png,
            contentType: "image/png",
            preferredFilename: "folder/leaf.png"
        )
        XCTAssertEqual(leaf.preferredFilename, "leaf.png")
    }

    func testMismatchedExtensionOrTypeIsRejected() {
        let normalizer = IOSImagePayloadNormalizer()
        let samples: [(Data, String, String)] = [
            (ImageBytes.png, "image/jpeg", "a.png"),
            (ImageBytes.jpeg, "image/png", "a.png"),
            (ImageBytes.png, "image/png", "a.jpg"),
            (ImageBytes.png, "image/png", "a.heic"),
            (ImageBytes.heic(), "image/png", "a.heic"),
            (ImageBytes.heic(), "image/heic", "a.png"),
            (ImageBytes.png, "application/octet-stream", "a.png"),
            (ImageBytes.png, "", "a.png"),
        ]
        for sample in samples {
            XCTAssertThrowsError(try normalizer.normalize(
                bytes: sample.0,
                contentType: sample.1,
                preferredFilename: sample.2
            )) { error in
                XCTAssertEqual(error as? IOSImageNormalizationError, .mismatchedRepresentation)
            }
        }
    }

    func testSVGInvalidBytesAndExecutablesAreRejected() async throws {
        let normalizer = IOSImagePayloadNormalizer()
        let samples: [(Data, String, String)] = [
            (ImageBytes.svg, "image/svg+xml", "diagram.svg"),
            (ImageBytes.svg, "image/png", "diagram.png"),
            (Data("<?xml version=\"1.0\"?><svg></svg>".utf8), "image/png", "diagram.png"),
            (ImageBytes.executable, "image/png", "run.png"),
            (Data([0x7F, 0x45, 0x4C, 0x46]), "image/png", "run.png"),
            (Data("#!/bin/sh".utf8), "image/png", "run.png"),
            (Data(), "image/png", "empty.png"),
            (Data([0x00, 0x01, 0x02, 0x03]), "image/png", "random.png"),
        ]
        for sample in samples {
            XCTAssertThrowsError(try normalizer.normalize(
                bytes: sample.0,
                contentType: sample.1,
                preferredFilename: sample.2
            )) { error in
                XCTAssertEqual(error as? IOSImageNormalizationError, .unsupportedType)
            }
        }

        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        await assertFailed(
            harness.insert(context, bytes: ImageBytes.svg, contentType: "image/svg+xml", filename: "diagram.svg"),
            .unsupportedType
        )
        XCTAssertEqual(harness.writer.calls, [])
        harness.assertSourceUntouched()
    }

    private func makeHEIC() throws -> Data {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let source = try XCTUnwrap(context)
        source.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        source.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(source.makeImage())
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.heic.identifier as CFString, 1, nil)
        let writer = try XCTUnwrap(destination, "HEIC ImageIO destination is unavailable")
        CGImageDestinationAddImage(writer, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return encoded as Data
    }
}
