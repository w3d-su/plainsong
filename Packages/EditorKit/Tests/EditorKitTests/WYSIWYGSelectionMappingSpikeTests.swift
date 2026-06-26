import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

final class WYSIWYGSelectionMappingSpikeTests: XCTestCase {
    func testSelectionAcrossFoldedBoldAndLinkExpandsToRawMarkdown() {
        let source = Self.foldedBoldAndLinkSource
        let projection = Self.foldedBoldAndLinkProjection(for: source)

        XCTAssertEqual(projection.visibleText, "A bold and link done")

        let visibleSelection = projection.visibleText.nsRange(of: "bold and link")
        let rawSelection = projection.rawSelectionRange(forVisibleRange: visibleSelection)

        XCTAssertEqual(source.substring(with: rawSelection), "**bold** and [link](https://example.com)")
    }

    func testShiftExtensionAcrossFoldedBoundariesHasNoHiddenDelimiterStops() {
        let source = Self.foldedBoldAndLinkSource
        let projection = Self.foldedBoldAndLinkProjection(for: source)

        let anchor = projection.visibleText.nsRange(of: "bold").location
        let afterFirstBoldCharacter = projection.visibleText.nsRange(of: "bo").location + 1
        let afterFoldedBold = NSMaxRange(projection.visibleText.nsRange(of: "bold"))
        let afterFoldedLink = NSMaxRange(projection.visibleText.nsRange(of: "link"))

        XCTAssertEqual(
            source.substring(with: projection.rawSelectionRange(
                forVisibleRange: NSRange(location: anchor, length: afterFirstBoldCharacter - anchor)
            )),
            "**b"
        )
        XCTAssertEqual(
            source.substring(with: projection.rawSelectionRange(
                forVisibleRange: NSRange(location: anchor, length: afterFoldedBold - anchor)
            )),
            "**bold**"
        )
        XCTAssertEqual(
            source.substring(with: projection.rawSelectionRange(
                forVisibleRange: NSRange(location: anchor, length: afterFoldedLink - anchor)
            )),
            "**bold** and [link](https://example.com)"
        )
    }

    func testSelectionStartingAfterFoldedBoldDoesNotCaptureTrailingDelimiter() {
        let source = Self.foldedBoldAndLinkSource
        let projection = Self.foldedBoldAndLinkProjection(for: source)

        let visibleSelection = projection.visibleText.nsRange(of: " and link")
        let rawSelection = projection.rawSelectionRange(forVisibleRange: visibleSelection)

        XCTAssertEqual(source.substring(with: rawSelection), " and [link](https://example.com)")
    }

    func testVisibleCaretOffsetsSkipHiddenDelimiterInteriorsForArrowAndMouseMapping() {
        let source = Self.foldedBoldAndLinkSource
        let projection = Self.foldedBoldAndLinkProjection(for: source)
        let visibleLength = (projection.visibleText as NSString).length

        let rawOffsets = (0 ... visibleLength).map { visibleOffset in
            let caretRange = projection.rawSelectionRange(forVisibleRange: NSRange(
                location: visibleOffset,
                length: 0
            ))
            XCTAssertEqual(caretRange.length, 0)
            XCTAssertFalse(
                projection.hasStrictHiddenInterior(at: caretRange.location),
                "Visible caret offset \(visibleOffset) mapped inside hidden delimiter source at \(caretRange.location)"
            )
            return caretRange.location
        }

        XCTAssertEqual(rawOffsets, rawOffsets.sorted())
        XCTAssertEqual(
            rawOffsets[projection.visibleText.nsRange(of: "bold").location],
            source.nsRange(of: "**bold**").location
        )
        XCTAssertEqual(
            rawOffsets[NSMaxRange(projection.visibleText.nsRange(of: "bold"))],
            NSMaxRange(source.nsRange(of: "**bold**"))
        )
        XCTAssertEqual(
            rawOffsets[projection.visibleText.nsRange(of: "link").location],
            source.nsRange(of: "[link](https://example.com)").location
        )
        XCTAssertEqual(
            rawOffsets[NSMaxRange(projection.visibleText.nsRange(of: "link"))],
            NSMaxRange(source.nsRange(of: "[link](https://example.com)"))
        )
    }

    func testFoldPlanSourceOffsetsForBoldAndFullLinkRevealRangeAreSane() throws {
        let source = Self.foldedBoldAndLinkSource
        let parser = try WYSIWYGFoldParser()
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let folded = parser.foldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: fullRange,
            selection: NSRange(location: 0, length: 0)
        )

        let strong = try folded.onlyRegion(kind: .strong)
        XCTAssertEqual(strong.sourceRange, source.nsRange(of: "**bold**"))
        XCTAssertEqual(strong.contentRange, source.nsRange(of: "bold"))
        XCTAssertEqual(source.substrings(with: strong.foldRanges), ["**", "**"])

        let linkSourceRange = source.nsRange(of: "[link](https://example.com)")
        let link = try folded.onlyRegion(kind: .link)
        XCTAssertEqual(link.sourceRange, linkSourceRange)
        XCTAssertEqual(link.contentRange, source.nsRange(of: "link"))
        XCTAssertEqual(link.revealRange, linkSourceRange)
        XCTAssertEqual(source.substrings(with: link.foldRanges), ["[", "](https://example.com)"])

        for revealOffset in [
            source.nsRange(of: "link").location,
            source.nsRange(of: "https://example.com").location,
            NSMaxRange(linkSourceRange) - 1,
        ] {
            let revealed = parser.foldPlan(
                in: source,
                fileKind: .markdown,
                visibleRange: fullRange,
                selection: NSRange(location: revealOffset, length: 0)
            )
            XCTAssertTrue(try revealed.onlyRegion(kind: .link).isRevealed)
        }

        let afterLink = parser.foldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: fullRange,
            selection: NSRange(location: NSMaxRange(linkSourceRange), length: 0)
        )
        XCTAssertFalse(try afterLink.onlyRegion(kind: .link).isRevealed)
    }

    @MainActor
    func testSTTextViewCopyUsesRawBackingStringForAttributedHiddenDelimiters() {
        let source = Self.foldedBoldAndLinkSource
        let textView = STTextView(frame: .zero)
        textView.text = source
        let rawSelection = source.nsRange(of: "**bold** and [link](https://example.com)")
        textView.textSelection = rawSelection

        let textStorage = MarkdownTextView.textStorage(of: textView)
        for delimiter in [
            source.nsRange(of: "**bold**", selecting: "**"),
            source.nsRange(of: "**bold**", selectingLast: "**"),
            source.nsRange(of: "[link]", selecting: "["),
            source.nsRange(of: "[link](https://example.com)", selecting: "](https://example.com)"),
        ] {
            textStorage?.addAttributes(
                [
                    .foregroundColor: NSColor.clear,
                    .font: NSFont.systemFont(ofSize: 0.1),
                ],
                range: delimiter
            )
        }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainsongWYSIWYGSpike.\(UUID().uuidString)"))
        pasteboard.clearContents()

        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "**bold** and [link](https://example.com)")
    }

    private static let foldedBoldAndLinkSource = "A **bold** and [link](https://example.com) done"

    private static func foldedBoldAndLinkProjection(for source: String) -> FoldedSourceProjection {
        FoldedSourceProjection(
            source: source,
            hiddenRanges: [
                .leading(source.nsRange(of: "**bold**", selecting: "**")),
                .trailing(source.nsRange(of: "**bold**", selectingLast: "**")),
                .leading(source.nsRange(of: "[link]", selecting: "[")),
                .trailing(source.nsRange(of: "[link](https://example.com)", selecting: "](https://example.com)")),
            ]
        )
    }
}

private struct FoldedSourceProjection {
    enum HiddenEdge {
        case leading
        case trailing
    }

    struct HiddenRange {
        var range: NSRange
        var edge: HiddenEdge

        static func leading(_ range: NSRange) -> Self {
            Self(range: range, edge: .leading)
        }

        static func trailing(_ range: NSRange) -> Self {
            Self(range: range, edge: .trailing)
        }
    }

    private enum SelectionEndpoint {
        case start
        case end
    }

    let source: String
    let hiddenRanges: [HiddenRange]

    var visibleText: String {
        var output = ""
        let nsSource = source as NSString
        var cursor = 0
        let hiddenRanges = sortedHiddenRanges()

        for hiddenRange in hiddenRanges {
            if cursor < hiddenRange.range.location {
                output += nsSource.substring(with: NSRange(
                    location: cursor,
                    length: hiddenRange.range.location - cursor
                ))
            }
            cursor = NSMaxRange(hiddenRange.range)
        }

        if cursor < nsSource.length {
            output += nsSource.substring(with: NSRange(location: cursor, length: nsSource.length - cursor))
        }

        return output
    }

    func rawSelectionRange(forVisibleRange visibleRange: NSRange) -> NSRange {
        let start = rawOffset(forVisibleOffset: visibleRange.location, endpoint: .start)
        let end = rawOffset(forVisibleOffset: NSMaxRange(visibleRange), endpoint: .end)
        return NSRange(location: start, length: max(0, end - start))
    }

    func hasStrictHiddenInterior(at rawOffset: Int) -> Bool {
        sortedHiddenRanges().contains { hiddenRange in
            rawOffset > hiddenRange.range.location && rawOffset < NSMaxRange(hiddenRange.range)
        }
    }

    private func rawOffset(forVisibleOffset visibleOffset: Int, endpoint: SelectionEndpoint) -> Int {
        let boundary = rawBoundary(forVisibleOffset: visibleOffset)
        var rawOffset = boundary.rawOffset

        for hiddenRange in boundary.hiddenRanges {
            switch (endpoint, hiddenRange.edge) {
            case (.start, .trailing), (.end, .trailing):
                rawOffset = NSMaxRange(hiddenRange.range)
            case (.start, .leading), (.end, .leading):
                return rawOffset
            }
        }

        return rawOffset
    }

    private func rawBoundary(forVisibleOffset targetVisibleOffset: Int) -> (
        rawOffset: Int,
        hiddenRanges: [HiddenRange]
    ) {
        let nsSource = source as NSString
        let hiddenRanges = sortedHiddenRanges()
        var hiddenIndex = 0
        var rawOffset = 0
        var visibleOffset = 0

        while rawOffset <= nsSource.length {
            if visibleOffset == targetVisibleOffset {
                return (
                    rawOffset,
                    contiguousHiddenRanges(startingAt: rawOffset, hiddenIndex: hiddenIndex, in: hiddenRanges)
                )
            }

            if hiddenIndex < hiddenRanges.count,
               hiddenRanges[hiddenIndex].range.location == rawOffset {
                rawOffset = NSMaxRange(hiddenRanges[hiddenIndex].range)
                hiddenIndex += 1
                continue
            }

            guard rawOffset < nsSource.length else {
                return (nsSource.length, [])
            }

            rawOffset += 1
            visibleOffset += 1
        }

        return (nsSource.length, [])
    }

    private func contiguousHiddenRanges(
        startingAt rawOffset: Int,
        hiddenIndex: Int,
        in hiddenRanges: [HiddenRange]
    ) -> [HiddenRange] {
        var ranges: [HiddenRange] = []
        var cursor = rawOffset
        var index = hiddenIndex

        while index < hiddenRanges.count, hiddenRanges[index].range.location == cursor {
            ranges.append(hiddenRanges[index])
            cursor = NSMaxRange(hiddenRanges[index].range)
            index += 1
        }

        return ranges
    }

    private func sortedHiddenRanges() -> [HiddenRange] {
        hiddenRanges.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.range.length < rhs.range.length
        }
    }
}

private extension WYSIWYGFoldPlan {
    func onlyRegion(
        kind: WYSIWYGFoldRegion.Kind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WYSIWYGFoldRegion {
        let matchingRegions = regions.filter { $0.kind == kind }
        XCTAssertEqual(matchingRegions.count, 1, file: file, line: line)
        return try XCTUnwrap(matchingRegions.first, file: file, line: line)
    }
}

private extension String {
    func nsRange(of substring: String) -> NSRange {
        let range = (self as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected substring '\(substring)' in '\(self)'")
        return range
    }

    func nsRange(of containingSubstring: String, selecting selectedSubstring: String) -> NSRange {
        let containerRange = nsRange(of: containingSubstring)
        let container = (self as NSString).substring(with: containerRange) as NSString
        let selectedRange = container.range(of: selectedSubstring)
        XCTAssertNotEqual(
            selectedRange.location,
            NSNotFound,
            "Expected substring '\(selectedSubstring)' in '\(containingSubstring)'"
        )
        return NSRange(location: containerRange.location + selectedRange.location, length: selectedRange.length)
    }

    func nsRange(of containingSubstring: String, selectingLast selectedSubstring: String) -> NSRange {
        let containerRange = nsRange(of: containingSubstring)
        let container = (self as NSString).substring(with: containerRange) as NSString
        let selectedRange = container.range(of: selectedSubstring, options: .backwards)
        XCTAssertNotEqual(
            selectedRange.location,
            NSNotFound,
            "Expected substring '\(selectedSubstring)' in '\(containingSubstring)'"
        )
        return NSRange(location: containerRange.location + selectedRange.location, length: selectedRange.length)
    }

    func substring(with range: NSRange) -> String {
        (self as NSString).substring(with: range)
    }

    func substrings(with ranges: [NSRange]) -> [String] {
        ranges.map { substring(with: $0) }
    }
}
