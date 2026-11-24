import CoreGraphics
import ImageIO
@testable import PlainsongIOS
import UniformTypeIdentifiers
import XCTest

final class IOSImagePhotoPayloadTests: XCTestCase {
    func testOrientedSourceIsWrittenUpright() throws {
        // 4x2 stored pixels tagged "rotate 90° clockwise to display" (a portrait photo).
        let source = try makeImage(width: 4, height: 2, type: .heic, orientation: 6)
        let png = try XCTUnwrap(IOSImageIORasterTranscoder().pngData(fromHEIC: source))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 4)
        let properties = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any]
        XCTAssertEqual((properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
    }

    func testUprightSourceKeepsItsSize() throws {
        let source = try makeImage(width: 4, height: 2, type: .heic, orientation: 1)
        let png = try XCTUnwrap(IOSImageIORasterTranscoder().pngData(fromHEIC: source))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 2)
    }

    func testGenericPhotosTypeIsAcceptedByItsBytes() throws {
        let picked = IOSImagePhotoPayloadLoader.payload(
            bytes: ImageBytes.jpeg, contentType: "public.image", preferredFilename: "IMG_0001"
        )
        let payload = try IOSImagePayloadNormalizer().normalize(
            bytes: picked.bytes, contentType: picked.contentType, preferredFilename: picked.preferredFilename
        )
        XCTAssertEqual(payload.contentType, "image/jpeg")
        XCTAssertEqual(payload.preferredFilename, "IMG_0001.jpg")
    }

    func testOriginalExtensionOnAConvertedRenditionIsAccepted() throws {
        let picked = IOSImagePhotoPayloadLoader.payload(
            bytes: ImageBytes.jpeg, contentType: "image/jpeg", preferredFilename: "IMG_0001.HEIC"
        )
        XCTAssertEqual(picked.preferredFilename, "IMG_0001.jpg")
        XCTAssertNoThrow(try IOSImagePayloadNormalizer().normalize(
            bytes: picked.bytes, contentType: picked.contentType, preferredFilename: picked.preferredFilename
        ))
    }

    func testUnrecognizedBytesAreStillRefused() {
        let picked = IOSImagePhotoPayloadLoader.payload(
            bytes: Data("<svg/>".utf8), contentType: "public.image", preferredFilename: "a.png"
        )
        XCTAssertThrowsError(try IOSImagePayloadNormalizer().normalize(
            bytes: picked.bytes, contentType: picked.contentType, preferredFilename: picked.preferredFilename
        ))
    }

    private func makeImage(width: Int, height: Int, type: UTType, orientation: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        )
        let properties = [kCGImagePropertyOrientation: orientation] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
