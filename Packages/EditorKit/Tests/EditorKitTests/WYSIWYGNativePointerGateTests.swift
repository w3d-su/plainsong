import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// True pointer hit-testing for the production `_developmentPresentation: .inlineFoldReveal`
/// hook. Unlike `WYSIWYGNativeInteractionGateTests` (which drives keyboard movement and raw
/// boundary selections), these tests lay the editor out in a real window, fold the inline
/// delimiters to ~zero width, and dispatch real `NSEvent` left-mouse-downs at the on-screen
/// position of folded content. The click coordinate comes from `firstRect(forCharacterRange:)`
/// and the resulting caret comes from STTextView's own `mouseDown` -> `caretLocation`
/// hit-test, so this exercises the production pointer path against laid-out hidden delimiters.
@MainActor
final class WYSIWYGNativePointerGateTests: XCTestCase {
    func testPointerClickOnFoldedHeadingContentRevealsMarkerWithoutTrap() throws {
        let source = "# Heading\n\nBody paragraph here"
        let fixture = try makeWindowedEditor(source: source)

        // Fold with the caret parked far away so the heading marker is hidden.
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: (source as NSString).length, length: 0),
            revision: 1,
            to: fixture.textView
        ))

        let headingContent = source.nsRange(of: "Heading")
        let caret = try pointerClick(onCharacterRange: headingContent, in: fixture)

        // Clicking the rendered heading text lands the caret on the heading line and reveals
        // its folded `# ` marker on the next presentation pass.
        let plan = try foldPlan(source: source, caret: caret)
        XCTAssertTrue(try plan.onlyRegion(matching: { if case .heading = $0 { true } else { false } }).isRevealed)
        try assertCaretNotTrapped(caret: caret, source: source)

        // A click on the body paragraph keeps the heading marker folded (no spurious reveal).
        let bodyCaret = try pointerClick(onCharacterRange: source.nsRange(of: "Body"), in: fixture)
        let bodyPlan = try foldPlan(source: source, caret: bodyCaret)
        XCTAssertFalse(try bodyPlan.onlyRegion(matching: { if case .heading = $0 { true } else { false } }).isRevealed)
        try assertCaretNotTrapped(caret: bodyCaret, source: source)
    }

    func testPointerClickAcrossFoldedInlineDelimitersPlacesSaneCaretAndReveals() throws {
        let source = "A **bold** mid ~~gone~~ and `code` end"
        let cases: [(content: String, kind: WYSIWYGFoldRegion.Kind)] = [
            ("bold", .strong),
            ("gone", .strikethrough),
            ("code", .inlineCode),
        ]

        for testCase in cases {
            let fixture = try makeWindowedEditor(source: source)

            XCTAssertTrue(applyProductionPresentation(
                source,
                selection: NSRange(location: 0, length: 0),
                revision: 1,
                to: fixture.textView
            ))

            // Click the rendered content word that sits between two folded delimiters.
            let caret = try pointerClick(onCharacterRange: source.nsRange(of: testCase.content), in: fixture)
            let plan = try foldPlan(source: source, caret: caret)
            XCTAssertTrue(
                try plan.onlyRegion(kind: testCase.kind).isRevealed,
                "Pointer click on \(testCase.content) should reveal its \(testCase.kind) span"
            )
            try assertCaretNotTrapped(caret: caret, source: source)

            // A click on the trailing "end" word keeps the span folded — the caret never
            // gets stuck inside the now-hidden closing delimiter.
            let endCaret = try pointerClick(onCharacterRange: source.nsRange(of: "end"), in: fixture)
            let endPlan = try foldPlan(source: source, caret: endCaret)
            XCTAssertFalse(
                try endPlan.onlyRegion(kind: testCase.kind).isRevealed,
                "Pointer click on trailing text should leave \(testCase.kind) folded"
            )
            try assertCaretNotTrapped(caret: endCaret, source: source)
        }
    }

    func testPointerBoundaryClicksAtFoldedDelimiterEdgesDoNotTrapCaret() throws {
        // The highest-risk pointer target is the seam between a folded (zero-width) delimiter
        // and the visible content next to it. Click the leading edge of the first content
        // character (abuts the hidden opening delimiter) and the trailing edge of the last
        // content character (abuts the hidden closing delimiter) for each construct.
        let source = "A **bold** mid ~~gone~~ and `code` end"
        let cases: [(content: String, kind: WYSIWYGFoldRegion.Kind)] = [
            ("bold", .strong),
            ("gone", .strikethrough),
            ("code", .inlineCode),
        ]

        for testCase in cases {
            let content = source.nsRange(of: testCase.content)
            let firstChar = NSRange(location: content.location, length: 1)
            let lastChar = NSRange(location: NSMaxRange(content) - 1, length: 1)

            for (charRange, fraction, edgeName) in [
                (firstChar, 0.08, "leading edge of \(testCase.content)"),
                (lastChar, 0.92, "trailing edge of \(testCase.content)"),
            ] {
                let fixture = try makeWindowedEditor(source: source)
                XCTAssertTrue(applyProductionPresentation(
                    source,
                    selection: NSRange(location: 0, length: 0),
                    revision: 1,
                    to: fixture.textView
                ))

                let caret = try pointerClick(onCharacterRange: charRange, in: fixture, fraction: fraction)
                // A boundary click reveals the span (caret falls within its reveal range) and
                // never leaves the caret stuck inside the now-hidden delimiter.
                let plan = try foldPlan(source: source, caret: caret)
                XCTAssertTrue(
                    try plan.onlyRegion(kind: testCase.kind).isRevealed,
                    "Boundary click at \(edgeName) should reveal \(testCase.kind)"
                )
                try assertCaretNotTrapped(caret: caret, source: source)
            }
        }
    }

    func testPointerDragSelectionAcrossFoldedSpansKeepsRawRangeAndCopy() throws {
        let source = "A **bold** mid ~~gone~~ and `code` end"
        let fixture = try makeWindowedEditor(source: source)

        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: fixture.textView
        ))

        // Anchor the pointer inside folded bold, then pointer-extend the selection (shift
        // click, the same hit-test + updateTextSelection path a drag uses) to inside folded
        // inline code. The dragged-over range crosses the hidden bold/strike/code delimiters.
        let boldContent = source.nsRange(of: "bold")
        let codeContent = source.nsRange(of: "code")
        _ = try pointerClick(onCharacterRange: boldContent, in: fixture)
        _ = try pointerClick(onCharacterRange: codeContent, in: fixture, shift: true)

        let selection = fixture.textView.selectedRange()
        XCTAssertGreaterThan(selection.length, 0, "Pointer drag should produce a non-empty selection")

        // Copy is exact raw source for the dragged range — folded delimiters between the
        // endpoints are included verbatim, not skipped or synthesized.
        let pasteboard = uniquePasteboard()
        XCTAssertTrue(fixture.textView.writeSelection(to: pasteboard, types: [.string]))
        let rawSelection = source.substring(with: selection)
        XCTAssertEqual(pasteboard.string(forType: .string), rawSelection)
        XCTAssertTrue(rawSelection.contains("**"), "Dragged range should include the folded bold delimiters")
        XCTAssertTrue(rawSelection.contains("~~"), "Dragged range should include the folded strike delimiters")
        XCTAssertTrue(rawSelection.contains("`"), "Dragged range should include the folded code delimiter")

        // Every span the drag touched reveals on the next presentation pass, and applying it
        // back to the live view preserves the pointer-extended selection.
        let presentation = productionPresentation(source, selection: selection, revision: 2)
        let plan = try XCTUnwrap(presentation.foldPlan)
        XCTAssertTrue(try plan.onlyRegion(kind: .strong).isRevealed)
        XCTAssertTrue(try plan.onlyRegion(kind: .strikethrough).isRevealed)
        XCTAssertTrue(try plan.onlyRegion(kind: .inlineCode).isRevealed)
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(presentation, to: fixture.textView))
        XCTAssertEqual(fixture.textView.selectedRange(), selection)
    }
}

@MainActor
private extension WYSIWYGNativePointerGateTests {
    struct WindowedEditor {
        let window: NSWindow
        let textView: MarkdownSTTextView
    }

    func makeWindowedEditor(source: String) throws -> WindowedEditor {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(
            scrollView.documentView as? MarkdownSTTextView,
            "Expected MarkdownSTTextView.scrollableTextView() to contain a MarkdownSTTextView"
        )
        textView.isEditable = true
        textView.isSelectable = true
        textView.showsLineNumbers = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager.ensureLayout(for: textView.textLayoutManager.documentRange)
        return WindowedEditor(window: window, textView: textView)
    }

    /// Dispatches a real left-mouse-down at the on-screen midpoint of `characterRange` and
    /// returns the resulting caret offset placed by STTextView's pointer hit-test.
    func pointerClick(
        onCharacterRange characterRange: NSRange,
        in fixture: WindowedEditor,
        shift: Bool = false,
        fraction: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int {
        let screenRect = fixture.textView.firstRect(forCharacterRange: characterRange, actualRange: nil)
        XCTAssertGreaterThan(
            screenRect.width,
            0,
            "Expected laid-out rect for \(characterRange)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            screenRect.height,
            0,
            "Expected laid-out rect for \(characterRange)",
            file: file,
            line: line
        )

        let screenPoint = CGPoint(x: screenRect.minX + screenRect.width * fraction, y: screenRect.midY)
        let windowPoint = fixture.window.convertPoint(fromScreen: screenPoint)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: shift ? .shift : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), file: file, line: line)

        fixture.textView.mouseDown(with: event)

        let caret = fixture.textView.selectedRange().location
        XCTAssertNotEqual(caret, NSNotFound, "Pointer click produced no caret", file: file, line: line)
        return caret
    }

    func foldPlan(source: String, caret: Int) throws -> WYSIWYGFoldPlan {
        try XCTUnwrap(productionPresentation(
            source,
            selection: NSRange(location: caret, length: 0),
            revision: 99
        ).foldPlan)
    }

    /// The "no trap" invariant: a caret must never sit inside a delimiter that stays folded
    /// (invisible) for that caret position.
    func assertCaretNotTrapped(
        caret: Int,
        source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let plan = try foldPlan(source: source, caret: caret)
        for region in plan.regions where !region.isRevealed {
            for fold in region.foldRanges where NSLocationInRange(caret, fold) {
                XCTFail(
                    "Caret \(caret) trapped inside folded \(region.kind) delimiter \(fold)",
                    file: file,
                    line: line
                )
            }
        }
    }

    func productionPresentation(_ source: String, selection: NSRange, revision: Int) -> HighlightedText {
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .inlineFoldReveal,
            selection: selection
        )
        return HighlightedText(
            revision: revision,
            range: highlighted.range,
            text: highlighted.text,
            foldPlan: highlighted.foldPlan
        )
    }

    @discardableResult
    func applyProductionPresentation(
        _ source: String,
        selection: NSRange,
        revision: Int,
        to textView: STTextView
    ) -> Bool {
        MarkdownTextView.applyHighlightedText(
            productionPresentation(source, selection: selection, revision: revision),
            to: textView
        )
    }

    func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainsongPointerGate.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }
}

private extension WYSIWYGFoldPlan {
    func onlyRegion(kind: WYSIWYGFoldRegion.Kind) throws -> WYSIWYGFoldRegion {
        let matching = regions.filter { $0.kind == kind }
        XCTAssertEqual(matching.count, 1)
        return try XCTUnwrap(matching.first)
    }

    func onlyRegion(matching predicate: (WYSIWYGFoldRegion.Kind) -> Bool) throws -> WYSIWYGFoldRegion {
        let matching = regions.filter { predicate($0.kind) }
        XCTAssertEqual(matching.count, 1)
        return try XCTUnwrap(matching.first)
    }
}

private extension String {
    func nsRange(of substring: String) -> NSRange {
        let range = (self as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected substring '\(substring)' in '\(self)'")
        return range
    }

    func substring(with range: NSRange) -> String {
        (self as NSString).substring(with: range)
    }
}
