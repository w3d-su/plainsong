@testable import EditorKitIOS
import SyntaxKit
import UIKit
import XCTest

final class IOSHighlightPresentationTests: XCTestCase {
    @MainActor
    func testRepeatedHighlightKeepsSourceSelectionAndUndo() async {
        let debounce = IOSDebounceGate()
        let syntax = IOSGatedTokenizer()
        let harness = makeHarness(debounce: debounce, syntax: syntax)
        let selection = harness.textView.selectedRange
        let undoBefore = harness.textView.undoManager?.canUndo
        await paint(harness, syntax: syntax, debounce: debounce, kind: .strong)
        harness.controller.noteViewportChanged()
        await paint(harness, syntax: syntax, debounce: debounce, kind: .inlineCode)
        XCTAssertEqual(harness.syntaxToken(at: 0), "inlineCode")
        XCTAssertEqual(harness.textView.textStorage.string, "alpha beta")
        XCTAssertEqual(harness.session.text, "alpha beta")
        XCTAssertEqual(harness.session.version, 0)
        XCTAssertEqual(harness.textView.selectedRange, selection)
        XCTAssertEqual(harness.textView.undoManager?.canUndo, undoBefore)
    }

    @MainActor
    func testStaleThemeAndViewportResultsAreDiscarded() async {
        let debounce = IOSDebounceGate()
        let syntax = IOSGatedTokenizer()
        let harness = makeHarness(debounce: debounce, syntax: syntax)
        await paint(harness, syntax: syntax, debounce: debounce, kind: .strong)

        harness.controller.theme = .dark
        await releaseAndPark(debounce, syntax: syntax)
        harness.controller.theme = .light
        await syntax.gate.resumeFirst(kind: .inlineCode)
        await Task.yield()
        XCTAssertNotEqual(harness.syntaxToken(at: 0), "inlineCode")
        await releaseAndPark(debounce, syntax: syntax)
        await syntax.gate.resumeFirst(kind: .emphasis)
        await iosWaitUntil("theme result") { harness.syntaxToken(at: 0) == "emphasis" }
        XCTAssertEqual(harness.session.version, 0)
        XCTAssertNotEqual(harness.textView.undoManager?.canUndo, true)

        harness.textView.viewportOverride = NSRange(location: 6, length: 4)
        harness.controller.noteViewportChanged()
        await releaseAndPark(debounce, syntax: syntax)
        harness.textView.viewportOverride = NSRange(location: 0, length: 5)
        harness.controller.noteViewportChanged()
        await syntax.gate.resumeFirst(kind: .linkText)
        await Task.yield()
        XCTAssertNotEqual(harness.syntaxToken(at: 6), "linkText")
        await releaseAndPark(debounce, syntax: syntax)
        await syntax.gate.resumeFirst(kind: .quoteMarker)
        await iosWaitUntil("viewport result") { harness.syntaxToken(at: 0) == "quoteMarker" }
        XCTAssertEqual(harness.textView.textStorage.string, "alpha beta")
    }

    @MainActor
    func testThemeSetsBaseFontAndColorBeforeSyntax() {
        let harness = IOSEditorHarness(text: "plain paragraph")
        let font = UIFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        let theme = IOSEditorTheme(
            identifier: "explicit-dark",
            background: .black,
            baseFont: font,
            baseColor: .white
        )
        let undoBefore = harness.textView.undoManager?.canUndo
        let version = harness.session.version
        harness.controller.theme = theme

        XCTAssertEqual(harness.textView.backgroundColor, .black)
        XCTAssertEqual(harness.textView.font?.pointSize, 18)
        XCTAssertEqual(harness.textView.textColor, .white)
        let typingFont = harness.textView.typingAttributes[.font] as? UIFont
        let typingColor = harness.textView.typingAttributes[.foregroundColor] as? UIColor
        XCTAssertEqual(typingFont?.pointSize, 18)
        XCTAssertEqual(typingColor, .white)
        let plainFont = harness.textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let plainColor = harness.textView.textStorage.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? UIColor
        XCTAssertEqual(plainFont?.pointSize, 18)
        XCTAssertEqual(plainColor, .white)

        let covered = NSRange(location: 0, length: harness.textView.textStorage.length)
        XCTAssertTrue(IOSHighlightPresenter.apply(
            tokens: [
                MarkdownSyntaxToken(kind: .strong, range: NSRange(location: 0, length: 5)),
            ],
            coveredRange: covered,
            expectedFragment: "plain paragraph",
            theme: theme,
            to: harness.textView
        ))
        let syntaxFont = harness.textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let bodyFont = harness.textView.textStorage.attribute(.font, at: 6, effectiveRange: nil) as? UIFont
        XCTAssertEqual(syntaxFont?.pointSize, 18)
        XCTAssertEqual(bodyFont?.pointSize, 18)
        XCTAssertEqual(
            harness.textView.typingAttributes[.font] as? UIFont,
            typingFont
        )
        XCTAssertEqual(harness.textView.textStorage.string, "plain paragraph")
        XCTAssertEqual(harness.session.text, "plain paragraph")
        XCTAssertEqual(harness.session.version, version)
        XCTAssertEqual(harness.textView.undoManager?.canUndo, undoBefore)
    }

    @MainActor
    func testThemeWaitsForMarkedTextBeforeRestyling() {
        let harness = IOSEditorHarness(text: "hello")
        harness.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 0, length: 1))
        let marked = harness.textView.textStorage.string
        let version = harness.session.version
        let undoBefore = harness.textView.undoManager?.canUndo
        let theme = IOSEditorTheme(
            identifier: "explicit-dark",
            background: .black,
            baseFont: UIFont.monospacedSystemFont(ofSize: 18, weight: .regular),
            baseColor: .white
        )
        harness.controller.theme = theme
        XCTAssertNotNil(harness.textView.markedTextRange)
        XCTAssertEqual(harness.textView.textStorage.string, marked)
        XCTAssertEqual(harness.session.version, version)
        XCTAssertEqual(harness.textView.undoManager?.canUndo, undoBefore)

        harness.textView.unmarkText()
        XCTAssertNil(harness.textView.markedTextRange)
        XCTAssertEqual(harness.textView.font?.pointSize, 18)
        XCTAssertEqual(harness.textView.textColor, .white)
        XCTAssertEqual((harness.textView.typingAttributes[.font] as? UIFont)?.pointSize, 18)
        XCTAssertEqual(harness.session.version, version)
        XCTAssertEqual(harness.textView.undoManager?.canUndo, undoBefore)
    }

    @MainActor
    func testClearingASyntaxTokenRestoresThemeBaseStyle() {
        let theme = IOSEditorTheme(
            identifier: "explicit-dark",
            background: .black,
            baseFont: UIFont.monospacedSystemFont(ofSize: 18, weight: .regular),
            baseColor: .white
        )
        let plain = IOSEditorHarness(text: "bold")
        plain.controller.theme = theme
        let plainFont = font(in: plain.textView, at: 0)
        let plainColor = color(in: plain.textView, at: 0)
        let plainBounds = typographicBounds(of: plain.textView)

        let harness = IOSEditorHarness(text: "**bold**")
        harness.controller.theme = theme
        let marked = NSRange(location: 0, length: iosUTF16("**bold**"))
        XCTAssertTrue(IOSHighlightPresenter.apply(
            tokens: [MarkdownSyntaxToken(kind: .strong, range: marked)],
            coveredRange: marked,
            expectedFragment: "**bold**",
            theme: theme,
            to: harness.textView
        ))
        XCTAssertEqual(harness.syntaxToken(at: 0), IOSSyntaxAttribute.token(for: .strong))

        harness.controller.isReconciling = true
        harness.textView.suppressesUndoRegistration = true
        let storage = harness.textView.textStorage
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 6, length: 2), with: "")
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
        storage.endEditing()
        harness.textView.suppressesUndoRegistration = false
        harness.controller.isReconciling = false

        let plainRange = NSRange(location: 0, length: iosUTF16("bold"))
        XCTAssertEqual(harness.textView.textStorage.string, "bold")
        XCTAssertTrue(IOSHighlightPresenter.apply(
            tokens: [],
            coveredRange: plainRange,
            expectedFragment: "bold",
            theme: theme,
            to: harness.textView
        ))
        XCTAssertNil(harness.syntaxToken(at: 0))
        let restoredFont = font(in: harness.textView, at: 0)
        let restoredColor = color(in: harness.textView, at: 0)
        XCTAssertEqual(restoredFont?.pointSize, plainFont?.pointSize)
        XCTAssertEqual(restoredFont?.fontName, plainFont?.fontName)
        XCTAssertEqual(restoredColor, plainColor)
        let restoredBounds = typographicBounds(of: harness.textView)
        XCTAssertEqual(restoredBounds.width, plainBounds.width, accuracy: 0.5)
        XCTAssertEqual(restoredBounds.height, plainBounds.height, accuracy: 0.5)
        XCTAssertEqual(harness.session.text, "**bold**")
        XCTAssertEqual(harness.session.version, 0)
        XCTAssertNotEqual(harness.textView.undoManager?.canUndo, true)
    }

    @MainActor
    private func font(in textView: UITextView, at location: Int) -> UIFont? {
        textView.textStorage.attribute(.font, at: location, effectiveRange: nil) as? UIFont
    }

    @MainActor
    private func color(in textView: UITextView, at location: Int) -> UIColor? {
        textView.textStorage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor
    }

    @MainActor
    private func typographicBounds(of textView: UITextView) -> CGSize {
        textView.layoutIfNeeded()
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager else {
            return .zero
        }
        manager.ensureLayout(for: content.documentRange)
        var size = CGSize.zero
        manager.enumerateTextLayoutFragments(
            from: content.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard !fragment.rangeInElement.isEmpty,
                  let line = fragment.textLineFragments.first(where: { $0.attributedString.length > 0 })
            else { return true }
            size = line.typographicBounds.size
            let lineFont = line.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
            let lineColor = line.attributedString.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
            let storageFont = textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
            let storageColor = textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
            XCTAssertEqual(lineFont?.pointSize, storageFont?.pointSize)
            XCTAssertEqual(lineFont?.fontName, storageFont?.fontName)
            XCTAssertEqual(lineColor, storageColor)
            return false
        }
        return size
    }

    @MainActor
    private func makeHarness(debounce: IOSDebounceGate, syntax: IOSGatedTokenizer) -> IOSEditorHarness {
        IOSEditorHarness(
            text: "alpha beta",
            tokenizer: syntax,
            debounce: debounce,
            syntax: syntax,
            viewport: NSRange(location: 0, length: iosUTF16("alpha beta"))
        )
    }

    @MainActor
    private func paint(
        _ harness: IOSEditorHarness,
        syntax: IOSGatedTokenizer,
        debounce: IOSDebounceGate,
        kind: MarkdownSyntaxToken.Kind
    ) async {
        await releaseAndPark(debounce, syntax: syntax)
        await syntax.gate.resumeFirst(kind: kind)
        await iosWaitUntil("paint \(kind)") { harness.syntaxToken(at: 0) == IOSSyntaxAttribute.token(for: kind) }
    }

    @MainActor
    private func releaseAndPark(_ debounce: IOSDebounceGate, syntax: IOSGatedTokenizer) async {
        await iosWaitUntil("debounce") { debounce.waiting >= 1 }
        let before = await syntax.gate.pendingCount()
        debounce.releaseNext()
        await iosWaitUntil("parked") { await syntax.gate.pendingCount() == before + 1 }
    }
}
