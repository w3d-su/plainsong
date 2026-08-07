import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

/// F8 — find-match decoration must survive a visible-range highlight recompute.
@MainActor
final class EditorFindMatchHighlightTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "find-highlight-doc")

    /// An attribute nothing preserves. Its removal proves the recompute really replaces the
    /// whole attribute dictionary, so the find attribute surviving the same pass is meaningful
    /// rather than an artifact of the pass being a no-op.
    private static let controlAttribute = NSAttributedString.Key("app.plainsong.test.control")

    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testFindHighlightSurvivesRecomputeWhileAnUnpreservedAttributeIsWiped() throws {
        let source = "alpha needle beta needle gamma delta\n"
        let text = source as NSString
        let first = text.range(of: "needle")
        let second = text.range(of: "needle", options: .backwards)
        let controlRange = text.range(of: "gamma")
        let fixture = try makeFixture(source: source)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))

        EditorFindMatchHighlight.apply(
            EditorFindMatchHighlightRequest(
                generation: 7,
                matches: [first, second],
                currentIndex: 1
            ),
            visibleRange: nil,
            previouslyDecorated: nil,
            to: storage
        )
        storage.addAttribute(Self.controlAttribute, value: true, range: controlRange)

        XCTAssertNotNil(marker(in: storage, at: first.location))
        XCTAssertEqual(
            storage.attribute(Self.controlAttribute, at: controlRange.location, effectiveRange: nil) as? Bool,
            true
        )

        // The recompute happens BETWEEN application and assertion — that is the gate.
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            plainPresentation(source, revision: 2),
            to: fixture.textView
        ))

        let survivingFirst = try XCTUnwrap(
            marker(in: storage, at: first.location),
            "other-match decoration must survive the recompute"
        )
        let survivingSecond = try XCTUnwrap(
            marker(in: storage, at: second.location),
            "current-match decoration must survive the recompute"
        )
        XCTAssertEqual(survivingFirst.role, .other)
        XCTAssertEqual(survivingSecond.role, .current)
        XCTAssertEqual(survivingFirst.generation, 7)
        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: second.location, effectiveRange: nil) as? NSColor,
            EditorFindMatchHighlight.backgroundColor(for: .current),
            "restoring the marker without its colour would leave a marked but invisible match"
        )

        XCTAssertNil(
            storage.attribute(Self.controlAttribute, at: controlRange.location, effectiveRange: nil),
            "Control: an unpreserved attribute must be wiped by the same pass, otherwise this test cannot fail"
        )
        XCTAssertEqual(EditorFindControllerTestSupport.viewText(in: fixture.textView), source)
    }

    func testApplyingANewerGenerationReplacesOlderDecoration() throws {
        let source = "one needle two needle three"
        let text = source as NSString
        let first = text.range(of: "needle")
        let second = text.range(of: "needle", options: .backwards)
        let fixture = try makeFixture(source: source)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))

        EditorFindMatchHighlight.apply(
            EditorFindMatchHighlightRequest(generation: 1, matches: [first, second], currentIndex: 0),
            visibleRange: nil,
            previouslyDecorated: nil,
            to: storage
        )
        EditorFindMatchHighlight.apply(
            EditorFindMatchHighlightRequest(generation: 2, matches: [second], currentIndex: 0),
            visibleRange: nil,
            previouslyDecorated: nil,
            to: storage
        )

        XCTAssertNil(marker(in: storage, at: first.location), "stale generation decoration must be removed, not merged")
        let current = try XCTUnwrap(marker(in: storage, at: second.location))
        XCTAssertEqual(current.generation, 2)
        XCTAssertEqual(current.role, .current)
    }

    func testOutOfBoundsMatchIsDroppedRatherThanClampedOntoOtherText() throws {
        let source = "short text"
        let fixture = try makeFixture(source: source)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        let beyondEnd = NSRange(location: (source as NSString).length - 2, length: 40)

        EditorFindMatchHighlight.apply(
            EditorFindMatchHighlightRequest(generation: 1, matches: [beyondEnd], currentIndex: 0),
            visibleRange: nil,
            previouslyDecorated: nil,
            to: storage
        )

        for location in 0 ..< storage.length {
            XCTAssertNil(
                marker(in: storage, at: location),
                "a match that no longer fits must be dropped, never retargeted at surviving characters"
            )
        }
    }

    func testClearRemovesBothTheMarkerAndItsColour() throws {
        let source = "clear needle please"
        let target = (source as NSString).range(of: "needle")
        let fixture = try makeFixture(source: source)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))

        EditorFindMatchHighlight.apply(
            EditorFindMatchHighlightRequest(generation: 1, matches: [target], currentIndex: 0),
            visibleRange: nil,
            previouslyDecorated: nil,
            to: storage
        )
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: target.location, effectiveRange: nil))

        EditorFindMatchHighlight.clear(in: storage)

        XCTAssertNil(marker(in: storage, at: target.location))
        XCTAssertNil(
            storage.attribute(.backgroundColor, at: target.location, effectiveRange: nil),
            "clearing the marker but leaving the colour would strand a highlight with no owner"
        )
    }

    // MARK: - Covered syntax background (P2)

    func testClearingRestoresTheSyntaxBackgroundTheMatchCoveredInsteadOfStrippingIt() throws {
        // A match that overlaps inline code: syntax highlighting owns `.backgroundColor` there.
        let source = "prefix `code needle span` suffix"
        let text = source as NSString
        let target = text.range(of: "needle")
        let codeRange = text.range(of: "`code needle span`")
        let codeBackground = NSColor.systemTeal
        let fixture = try makeFixture(source: source)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        storage.addAttribute(.backgroundColor, value: codeBackground, range: codeRange)

        EditorFindMatchHighlight.apply(
            EditorFindMatchHighlightRequest(generation: 1, matches: [target], currentIndex: 0),
            visibleRange: nil,
            previouslyDecorated: nil,
            to: storage
        )
        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: target.location, effectiveRange: nil) as? NSColor,
            EditorFindMatchHighlight.backgroundColor(for: .current),
            "the find highlight should be on top while find is open"
        )

        EditorFindMatchHighlight.clear(in: storage)

        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: target.location, effectiveRange: nil) as? NSColor,
            codeBackground,
            "clearing must put back the code background it covered, not strip it"
        )
        // The parts of the code span the match never covered must be untouched throughout.
        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor,
            codeBackground
        )
    }

    func testClearingShiftedMarkerRestoresCoveredBackgroundAtItsEditedLocation() {
        let source = "alpha needle beta"
        let target = (source as NSString).range(of: "needle")
        let storage = NSTextStorage(string: source)
        let syntaxBackground = NSColor.systemTeal
        storage.addAttribute(.backgroundColor, value: syntaxBackground, range: target)
        let request = EditorFindMatchHighlightRequest(
            generation: 1,
            matches: [target],
            currentIndex: 0
        )
        _ = EditorFindMatchHighlight.apply(
            request,
            visibleRange: NSRange(location: 0, length: storage.length),
            previouslyDecorated: nil,
            to: storage
        )

        let prefix = String(repeating: "x", count: 6000)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: prefix)
        let shifted = NSRange(location: target.location + prefix.utf16.count, length: target.length)
        EditorFindMatchHighlight.clear(in: storage, searching: shifted)

        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: shifted.location, effectiveRange: nil) as? NSColor,
            syntaxBackground
        )
        XCTAssertNil(storage.attribute(.backgroundColor, at: target.location, effectiveRange: nil))
    }

    func testClearingLeavesPlainTextWithNoBackgroundRatherThanInventingOne() throws {
        let source = "plain needle text"
        let target = (source as NSString).range(of: "needle")
        let fixture = try makeFixture(source: source)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))

        EditorFindMatchHighlight.apply(
            EditorFindMatchHighlightRequest(generation: 1, matches: [target], currentIndex: 0),
            visibleRange: nil,
            previouslyDecorated: nil,
            to: storage
        )
        EditorFindMatchHighlight.clear(in: storage)

        XCTAssertNil(
            storage.attribute(.backgroundColor, at: target.location, effectiveRange: nil),
            "nothing was covered here, so nothing may be restored"
        )
    }

    private func makeFixture(source: String) throws -> EditorFindControllerTestSupport.WindowedFixture {
        let model = EditorFindControllerTestSupport.FindNavModel(
            text: source,
            selection: NSRange(location: 0, length: 0)
        )
        return try EditorFindControllerTestSupport.makeWindowedFixture(
            model: model,
            source: source,
            documentIdentity: documentA
        )
    }

    private func marker(
        in storage: NSTextStorage,
        at location: Int
    ) -> EditorFindMatchHighlightMarker? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(
            EditorFindMatchHighlightMarker.attribute,
            at: location,
            effectiveRange: nil
        ) as? EditorFindMatchHighlightMarker
    }

    /// Ordinary source-mode presentation over the whole document — the recompute shape that
    /// wipes attributes in production.
    private func plainPresentation(_ source: String, revision: Int) -> HighlightedText {
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .source,
            selection: NSRange(location: 0, length: 0)
        )
        return HighlightedText(
            revision: revision,
            range: highlighted.range,
            text: highlighted.text,
            foldPlan: highlighted.foldPlan
        )
    }
}
