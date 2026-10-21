import ImageIO
@testable import PlainsongIOS
import XCTest

@MainActor
final class IOSImageRasterValidationTests: XCTestCase {
    func testRealRasterFixturesDecodeAndRemainUnchanged() throws {
        let samples: [(Data, String, String)] = [
            (ImageBytes.png, "image/png", "a.png"),
            (ImageBytes.jpeg, "image/jpeg", "a.jpg"),
            (ImageBytes.gif, "image/gif", "a.gif"),
            (ImageBytes.gif87, "image/gif", "old.gif"),
            (ImageBytes.webp, "image/webp", "a.webp"),
        ]
        for (bytes, type, filename) in samples {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil), filename)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), filename)
            XCTAssertEqual(image.width, 1, filename)
            XCTAssertEqual(image.height, 1, filename)
            let payload = try IOSImagePayloadNormalizer().normalize(
                bytes: bytes, contentType: type, preferredFilename: filename
            )
            XCTAssertEqual(payload.bytes, bytes, filename)
        }
    }

    func testSignatureOnlyRastersNeverReachPersistence() async throws {
        var webp = Data("RIFF".utf8)
        webp.append(contentsOf: [0x10, 0x00, 0x00, 0x00])
        webp.append(contentsOf: "WEBP".utf8)
        webp.append(contentsOf: [0, 0, 0, 0])
        let samples: [(Data, String, String)] = [
            (Data(ImageBytes.pngSignature), "image/png", "fake.png"),
            (Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10]), "image/jpeg", "fake.jpg"),
            (Data("GIF87a".utf8), "image/gif", "fake.gif"),
            (Data("GIF89a".utf8), "image/gif", "fake.gif"),
            (webp, "image/webp", "fake.webp"),
        ]
        for (bytes, type, filename) in samples {
            let harness = ImageInsertionHarness()
            let context = try harness.capture()
            await assertFailed(
                harness.insert(context, bytes: bytes, contentType: type, filename: filename),
                .unsupportedType
            )
            XCTAssertEqual(harness.writer.calls, [], filename)
            harness.assertSourceUntouched()
        }
    }

    func testTruncatedRealRastersNeverReachPersistence() async throws {
        let samples: [(Data, String, String)] = [
            (Data(ImageBytes.png.prefix(24)), "image/png", "cut.png"),
            (Data(ImageBytes.jpeg.prefix(32)), "image/jpeg", "cut.jpg"),
            (Data(ImageBytes.gif.prefix(13)), "image/gif", "cut.gif"),
            (Data(ImageBytes.webp.prefix(20)), "image/webp", "cut.webp"),
        ]
        for (bytes, type, filename) in samples {
            let harness = ImageInsertionHarness()
            let context = try harness.capture()
            await assertFailed(
                harness.insert(context, bytes: bytes, contentType: type, filename: filename),
                .unsupportedType
            )
            XCTAssertEqual(harness.writer.calls, [], filename)
            harness.assertSourceUntouched()
        }
    }

    func testHEICTranscoderMustReturnCompletePNG() async throws {
        let transcoder = RecordingTranscoder(png: Data(ImageBytes.pngSignature))
        let harness = ImageInsertionHarness(transcoder: transcoder)
        let context = try harness.capture()
        await assertFailed(harness.insert(
            context, bytes: ImageBytes.heic(), contentType: "image/heic", filename: "photo.heic"
        ), .unsupportedType)
        XCTAssertEqual(harness.writer.calls, [])
        XCTAssertFalse(transcoder.observedMainThread)
        harness.assertSourceUntouched()
    }
}
