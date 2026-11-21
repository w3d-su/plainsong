import CoreGraphics
import Foundation
import ImageIO
@testable import PreviewKit
import UniformTypeIdentifiers
import XCTest

final class ExportRasterPixelBoundTests: XCTestCase {
    func testOrdinaryImageStillDecodes() throws {
        XCTAssertEqual(ExportRasterSniffer.decodedMIMEType(of: try png(width: 64, height: 48)), "image/png")
    }

    func testImageAtTheBoundDecodesAndOnePastItIsRejectedBeforeDecoding() throws {
        let atBound = try png(width: ExportRasterSniffer.maximumPixelCount / 4096, height: 4096)
        let pastBound = try png(width: ExportRasterSniffer.maximumPixelCount / 4096 + 1, height: 4096)
        XCTAssertLessThan(pastBound.count, Int(ExportRasterSniffer.maximumRasterBytes))

        XCTAssertEqual(ExportRasterSniffer.decodedMIMEType(of: atBound), "image/png")
        let started = Date()
        XCTAssertNil(ExportRasterSniffer.decodedMIMEType(of: pastBound))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "the rejection must not decode the pixels")
    }

    /// A one-bit gray canvas left blank, so the PNG stays small at any size.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
