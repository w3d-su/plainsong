import Foundation
import ImageIO
@testable import PreviewKit
import UniformTypeIdentifiers
import XCTest

final class ExportResourceResolverReviewTests: XCTestCase {
    /// R19: one accepted image referenced many times must cross the bridge once, not once
    /// per reference (100 references to a 10 MiB PNG were a ~1.3 GB finalization string).
    func testHundredReferencesToOneImageSerializeItsDataURIOnce() throws {
        let root = try makeRoot()
        try ExportRasterFixture.png(exactByteCount: 1 << 20).write(to: root.appendingPathComponent("shared.png"))
        let resources = (0 ..< 100).map {
            ExportResourceDescriptor(resourceID: "image-\($0)", kind: .image, src: "asset://shared.png")
        }

        let outcomes = ExportResourceResolver.resolve(resources, assetRoot: root, previewDirectory: nil)
        let payload = try JSONEncoder().encode(ExportHTMLPayload(
            exportID: 1,
            renderID: 1,
            phase: .finalization,
            resourceOutcomes: outcomes
        ))

        XCTAssertEqual(outcomes.map(\.action), Array(repeating: .embed, count: 100))
        let carriers = outcomes.compactMap(\.dataURI)
        XCTAssertEqual(carriers.count, 1)
        let dataURI = try XCTUnwrap(carriers.first)
        XCTAssertLessThan(payload.count, dataURI.utf8.count + 100 * 256)
    }

    /// `CGImageSourceGetType` reads only the signature; these type-sniff as rasters but
    /// cannot decode, so neither an authored `data:` image nor a contained asset may embed.
    func testTypeSniffedRastersThatDoNotDecodeAreOmitted() throws {
        let png = try ExportRasterFixture.encoded(.png)
        let jpeg = try ExportRasterFixture.encoded(.jpeg)
        var corruptPNG = png
        for offset in 41 ..< (png.count - 16) {
            corruptPNG[offset] = 0x55
        }
        let fixtures = [
            UndecodableRaster(name: "header-only.png", data: png.prefix(33) + png.suffix(12), mimeType: "image/png"),
            UndecodableRaster(name: "corrupt.png", data: corruptPNG, mimeType: "image/png"),
            UndecodableRaster(name: "header-only.jpg", data: jpeg.prefix(160), mimeType: "image/jpeg"),
        ]
        let root = try makeRoot()
        var resources: [ExportResourceDescriptor] = []
        for fixture in fixtures {
            let source = CGImageSourceCreateWithData(fixture.data as CFData, nil)
            XCTAssertNotNil(source.flatMap(CGImageSourceGetType), "\(fixture.name) must still type-sniff")
            try fixture.data.write(to: root.appendingPathComponent(fixture.name))
            resources.append(ExportResourceDescriptor(
                resourceID: "asset-\(fixture.name)",
                kind: .image,
                src: "asset://\(fixture.name)"
            ))
            resources.append(ExportResourceDescriptor(
                resourceID: "data-\(fixture.name)",
                kind: .image,
                src: "data:\(fixture.mimeType);base64,\(fixture.data.base64EncodedString())"
            ))
        }

        let outcomes = ExportResourceResolver.resolve(resources, assetRoot: root, previewDirectory: nil)

        for outcome in outcomes {
            XCTAssertEqual(outcome.action, .omit, outcome.resourceID)
            XCTAssertNil(outcome.dataURI, outcome.resourceID)
        }
        let valid = ExportResourceResolver.resolve(
            [ExportResourceDescriptor(
                resourceID: "valid",
                kind: .image,
                src: "data:image/png;base64,\(png.base64EncodedString())"
            )],
            assetRoot: nil,
            previewDirectory: nil
        )
        XCTAssertEqual(valid.first?.action, .embed)
    }

    /// Repeated authored `data:` images are answered from the first decision before any
    /// base64 or ImageIO work; only a distinct normalizer input is decoded.
    func testRepeatedAuthoredDataImagesAreLookedUpBeforeDecoding() throws {
        let base64 = try ExportRasterFixture.encoded(.png).base64EncodedString()
        let spellings = ["data:image/png;base64,\(base64)", "  DATA:Image/PNG ; Base64,\(base64)  "]
        var resources = (0 ..< 100).map {
            ExportResourceDescriptor(resourceID: "image-\($0)", kind: .image, src: spellings[$0 % 2])
        }
        resources += (0 ..< 10).map {
            ExportResourceDescriptor(resourceID: "broken-\($0)", kind: .image, src: "data:image/png;base64,@@@")
        }
        // Inner whitespace changes what the MIME check sees, so it must not share a key.
        resources.append(ExportResourceDescriptor(
            resourceID: "spaced-mime",
            kind: .image,
            src: "data:image/ png;base64,\(base64)"
        ))

        var decodes = 0
        let outcomes = ExportResourceResolver.resolve(resources, assetRoot: nil, previewDirectory: nil) { source in
            decodes += 1
            return ExportRasterDataURI.normalized(from: source)
        }

        XCTAssertEqual(decodes, 3)
        XCTAssertNotNil(outcomes[0].dataURI)
        XCTAssertTrue(outcomes[1 ..< 100].allSatisfy {
            $0.action == .embed && $0.dataURI == nil && $0.dataURIFrom == "image-0"
        })
        XCTAssertTrue(outcomes[100 ..< 110].allSatisfy { $0.action == .omit && $0.reason == "malformed-data" })
        XCTAssertEqual(outcomes.last?.action, .omit)
        XCTAssertEqual(outcomes.last?.reason, "malformed-data")
    }

    private struct UndecodableRaster {
        let name: String
        let data: Data
        let mimeType: String
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plainsong-export-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
