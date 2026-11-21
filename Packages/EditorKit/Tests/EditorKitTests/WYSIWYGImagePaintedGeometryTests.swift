import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// The image canvas must paint inside the line TextKit reserved for it, measured in pixels.
/// Two offsets moved the painting while every layout frame stayed correct: the attachment
/// hung from the baseline of a font whose ascender is only about four fifths of the canvas,
/// and STTextView raised the tall line by half the height its 1.25 line-height multiple would
/// add. A missing file's 240 pt placeholder covered the heading and paragraph lines above it.
@MainActor
final class WYSIWYGImagePaintedGeometryTests: XCTestCase {
    private typealias Support = WYSIWYGImageThumbnailGateSupport

    /// `MarkdownTextView`'s default, which the app installs on every editor.
    private static let appLineHeightMultiple: CGFloat = 1.25

    func testMissingFilePlaceholderPaintsInsideItsOwnLineAtTheAppLineHeightMultiple() async throws {
        try await assertCanvasPaintsInsideItsLine(
            imageLine: "![sample](assets/image-00001.png)",
            outcomes: [:],
            expectedState: .failed,
            lineHeightMultiple: Self.appLineHeightMultiple
        )
    }

    func testMissingFilePlaceholderPaintsInsideItsOwnLineWithoutAMultiple() async throws {
        try await assertCanvasPaintsInsideItsLine(
            imageLine: "![sample](assets/image-00001.png)",
            outcomes: [:],
            expectedState: .failed,
            lineHeightMultiple: nil
        )
    }

    func testInlineMissingFilePlaceholderPaintsInsideItsOwnLineAtTheAppLineHeightMultiple() async throws {
        try await assertCanvasPaintsInsideItsLine(
            imageLine: "See ![sample](assets/image-00001.png) here.",
            outcomes: [:],
            expectedState: .failed,
            lineHeightMultiple: Self.appLineHeightMultiple
        )
    }

    func testReadyThumbnailPaintsInsideItsOwnLineAtTheAppLineHeightMultiple() async throws {
        let ready = Support.readyOutcome(source: "fixture.png", resolvedPath: "posts/fixture.png")
        try await assertCanvasPaintsInsideItsLine(
            imageLine: "![sample](fixture.png)",
            outcomes: ["fixture.png": ready],
            expectedState: nil,
            lineHeightMultiple: Self.appLineHeightMultiple
        )
    }

    private struct PresentedImage {
        let fixture: WYSIWYGImageThumbnailGateSupport.WindowedEditor
        let marker: WYSIWYGImagePresentationMarker
        let imageRange: NSRange
        let aboveRange: NSRange
    }

    private func assertCanvasPaintsInsideItsLine(
        imageLine: String,
        outcomes: [String: EditorImageThumbnailOutcome],
        expectedState: WYSIWYGImagePresentationMarker.VisualState?,
        lineHeightMultiple: CGFloat?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let presented = try await presentImage(
            imageLine: imageLine,
            outcomes: outcomes,
            expectedState: expectedState,
            lineHeightMultiple: lineHeightMultiple,
            file: file,
            line: line
        )
        let textView = presented.fixture.textView
        let imageLineFrame = try Support.lineFragmentFrame(containing: presented.imageRange, in: textView)
        let aboveLineFrame = try Support.lineFragmentFrame(containing: presented.aboveRange, in: textView)
        let canvasMinX = try attachmentMinX(at: presented.imageRange.location, in: textView)
            + (textView.gutterView?.frame.width ?? 0)
        XCTAssertGreaterThanOrEqual(
            imageLineFrame.height,
            presented.marker.canvasSize.height - 2,
            "the line reserves the canvas",
            file: file,
            line: line
        )

        // Right of the alt chip and the thumbnail's content, left of the rounded corners:
        // only the canvas fill and stroke paint this column. Far right of every line's text
        // is the background it is compared against.
        let painted = try XCTUnwrap(
            paintedRows(
                in: render(textView),
                of: textView,
                probeX: canvasMinX + presented.marker.canvasSize.width - 12,
                referenceX: textView.bounds.width - 8
            ),
            "the canvas painted nothing in its column",
            file: file,
            line: line
        )

        let context = "multiple \(lineHeightMultiple.map { "\($0)" } ?? "none"), line \(imageLineFrame), "
            + "painted \(painted)"
        XCTAssertGreaterThanOrEqual(
            painted.minY,
            aboveLineFrame.maxY - 1,
            "the canvas paints over the line above it (\(context))",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(painted.minY, imageLineFrame.minY - 1, context, file: file, line: line)
        XCTAssertLessThanOrEqual(painted.maxY, imageLineFrame.maxY + 1, context, file: file, line: line)
        XCTAssertLessThanOrEqual(
            painted.minY,
            imageLineFrame.minY + 3,
            "the canvas leaves a gap at the top of its line (\(context))",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            painted.maxY,
            imageLineFrame.maxY - 3,
            "the canvas leaves a gap below it in its line (\(context))",
            file: file,
            line: line
        )
    }

    /// Opens `imageLine` between short siblings and waits for its presentation;
    /// `expectedState` nil waits for a ready thumbnail.
    private func presentImage(
        imageLine: String,
        outcomes: [String: EditorImageThumbnailOutcome],
        expectedState: WYSIWYGImagePresentationMarker.VisualState?,
        lineHeightMultiple: CGFloat?,
        file: StaticString,
        line: UInt
    ) async throws -> PresentedImage {
        // Short sibling lines keep their text out of the pixel column the canvas is read in.
        let source = "Top\nAbove\n\(imageLine)\nBelow\n" as NSString
        let imageStart = source.range(of: "![sample]").location
        let imageEnd = source.range(
            of: ")",
            range: NSRange(location: imageStart, length: source.length - imageStart)
        ).location + 1
        let imageRange = NSRange(location: imageStart, length: imageEnd - imageStart)
        let fixture = try Support.makeWindowedEditor(
            source: source as String,
            frame: NSRect(x: 0, y: 0, width: 760, height: 520),
            outcomes: outcomes,
            lineHeightMultiple: lineHeightMultiple,
            file: file,
            line: line
        )
        fixture.window.appearance = NSAppearance(named: .aqua)
        let marker = try await Support.waitForMarker(in: fixture.textView, range: imageRange) { marker in
            if let expectedState {
                return marker.visualState == expectedState
            }
            if case .ready = marker.visualState {
                return true
            }
            return false
        }
        _ = try Support.assertLiveAttachment(
            in: fixture.textView,
            imageRange: imageRange,
            expectedSize: marker.canvasSize,
            file: file,
            line: line
        )
        return PresentedImage(
            fixture: fixture,
            marker: marker,
            imageRange: imageRange,
            aboveRange: source.range(of: "Above")
        )
    }

    /// The attachment character's left edge in text-container coordinates.
    private func attachmentMinX(at location: Int, in textView: STTextView) throws -> CGFloat {
        let layoutManager = textView.textLayoutManager
        let range = try XCTUnwrap(NSTextRange(
            NSRange(location: location, length: 1),
            in: textView.textContentManager
        ))
        var minX: CGFloat?
        layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            minX = frame.minX
            return false
        }
        return try XCTUnwrap(minX)
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.window?.layoutIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The vertical extent, in view points, of the pixels in column `probeX` that differ
    /// from the same row at `referenceX`.
    private func paintedRows(
        in rep: NSBitmapImageRep,
        of view: NSView,
        probeX: CGFloat,
        referenceX: CGFloat
    ) -> (minY: CGFloat, maxY: CGFloat)? {
        XCTAssertTrue(view.isFlipped)
        let scaleX = CGFloat(rep.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / view.bounds.height
        let probeColumn = Int((probeX * scaleX).rounded(.down))
        let referenceColumn = Int((referenceX * scaleX).rounded(.down))
        var first: Int?
        var last: Int?
        for row in 0 ..< rep.pixelsHigh
            where differs(rep.colorAt(x: probeColumn, y: row), rep.colorAt(x: referenceColumn, y: row))
        {
            first = first ?? row
            last = row
        }
        guard let first, let last else { return nil }
        return (CGFloat(first) / scaleY, CGFloat(last + 1) / scaleY)
    }

    /// The canvas fill is 8% opaque; anything that faint or stronger counts as paint.
    private func differs(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        guard let lhs = lhs?.usingColorSpace(.deviceRGB), let rhs = rhs?.usingColorSpace(.deviceRGB) else {
            return false
        }
        let delta = abs(lhs.redComponent - rhs.redComponent) + abs(lhs.greenComponent - rhs.greenComponent)
            + abs(lhs.blueComponent - rhs.blueComponent) + abs(lhs.alphaComponent - rhs.alphaComponent)
        return delta > 0.03
    }
}
