import AppKit
@testable import EditorKit
import MarkdownCore
import SwiftUI
import XCTest

@MainActor
final class MarkdownSyntaxThemeCustomTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testBuiltInChromeMatchesTheSystemColorsTheEditorAlreadyUsed() {
        let standard = MarkdownSyntaxTheme.standard
        XCTAssertEqual(standard.backgroundColor, .textBackgroundColor)
        XCTAssertEqual(standard.selectionColor, .selectedTextBackgroundColor)
        XCTAssertEqual(standard.caretColor, .textInsertionPointColor)
        XCTAssertNil(standard.gutterBackgroundColor)

        let graphite = MarkdownSyntaxTheme.graphite
        XCTAssertEqual(graphite.backgroundColor, standard.backgroundColor)
        XCTAssertNil(graphite.gutterBackgroundColor)
    }

    func testCustomColorsFollowAppearanceWithoutReloadingADocument() throws {
        let document = try CustomThemeValidation.validate(Data("""
        {
          "schemaVersion": 1,
          "id": "ink",
          "name": "Ink",
          "light": {"editor": {
            "text": "#112233",
            "background": "#F4F4F4",
            "selection": "#CCE4FF",
            "caret": "#FF0000",
            "gutter": "#EEEEEE"
          }},
          "dark": {"editor": {
            "text": "#DDEEFF",
            "background": "#111111",
            "selection": "#334455",
            "caret": "#00FF00"
          }}
        }
        """.utf8)).get()
        let theme = MarkdownSyntaxTheme.resolving(document)

        XCTAssertEqual(components(theme.textColor, appearance: .aqua).red, 0x11 / 255, accuracy: 0.01)
        XCTAssertEqual(components(theme.textColor, appearance: .darkAqua).red, 0xDD / 255, accuracy: 0.01)
        XCTAssertEqual(components(theme.backgroundColor, appearance: .aqua).red, 0xF4 / 255, accuracy: 0.01)
        XCTAssertEqual(components(theme.backgroundColor, appearance: .darkAqua).red, 0x11 / 255, accuracy: 0.01)
        XCTAssertNotNil(theme.gutterBackgroundColor)
        XCTAssertEqual(
            try components(XCTUnwrap(theme.gutterBackgroundColor), appearance: .aqua).red,
            0xEE / 255,
            accuracy: 0.01
        )
        // Dark omits gutter, so that appearance keeps the built-in background color.
        let gutter = try components(XCTUnwrap(theme.gutterBackgroundColor), appearance: .darkAqua)
        let builtIn = components(MarkdownSyntaxTheme.standard.backgroundColor, appearance: .darkAqua)
        XCTAssertEqual(gutter.red, builtIn.red, accuracy: 0.02)
        XCTAssertEqual(gutter.green, builtIn.green, accuracy: 0.02)
        XCTAssertEqual(gutter.blue, builtIn.blue, accuracy: 0.02)
    }

    func testOmittedSlotsInheritTheBuiltInColor() throws {
        let document = try CustomThemeValidation.validate(Data("""
        {"schemaVersion":1,"id":"ink","name":"Ink","light":{"editor":{"heading":"#010203"}}}
        """.utf8)).get()
        let theme = MarkdownSyntaxTheme.resolving(document)
        XCTAssertEqual(theme.textColor, MarkdownSyntaxTheme.standard.textColor)
        XCTAssertEqual(theme.backgroundColor, MarkdownSyntaxTheme.standard.backgroundColor)
        XCTAssertNil(theme.gutterBackgroundColor)
        XCTAssertNotEqual(theme.headingColor, MarkdownSyntaxTheme.standard.headingColor)
    }

    func testThemeSwitchRecolorsWithoutReplacingTheDocumentText() throws {
        let source = "Theme switch keeps this exact text."
        var text = source
        var selection: NSRange?
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let selectionBinding = Binding(get: { selection }, set: { selection = $0 })
        let frame = NSRect(x: 0, y: 0, width: 560, height: 180)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        let initial = MarkdownTextView(
            text: textBinding,
            styledText: nil,
            selection: selectionBinding,
            showsLineNumbers: true
        )
        let coordinator = initial.makeCoordinator()
        textView.textDelegate = coordinator
        let window = EditorFindControllerTestSupport.registerWindowForTeardown(NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        ))
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        initial.updateRepresentedTextView(scrollView, coordinator: coordinator)
        textView.text = source
        let installed = MarkdownTextView.textStorage(of: textView)

        let custom = try CustomThemeValidation.validate(Data("""
        {
          "schemaVersion": 1,
          "id": "ink",
          "name": "Ink",
          "light": {"editor": {
            "background": "#010203",
            "selection": "#445566",
            "caret": "#778899",
            "gutter": "#AABBCC"
          }}
        }
        """.utf8)).get()
        let resolved = MarkdownSyntaxTheme.resolving(custom)
        // Same id and hex must stay equal, or the next highlight would re-typeset.
        XCTAssertEqual(resolved.backgroundColor, MarkdownSyntaxTheme.resolving(custom).backgroundColor)
        XCTAssertEqual(resolved.selectionColor, MarkdownSyntaxTheme.resolving(custom).selectionColor)
        let updated = MarkdownTextView(
            text: textBinding,
            styledText: nil,
            selection: selectionBinding,
            showsLineNumbers: true,
            syntaxTheme: resolved
        )
        updated.updateRepresentedTextView(scrollView, coordinator: coordinator)

        XCTAssertTrue(MarkdownTextView.textStorage(of: textView) === installed)
        XCTAssertEqual(textView.text, source)
        XCTAssertEqual(text, source)
        XCTAssertEqual(
            try components(XCTUnwrap(textView.backgroundColor), appearance: .aqua).red,
            1 / 255,
            accuracy: 0.01
        )
        XCTAssertEqual(
            components(textView.insertionPointColor, appearance: .aqua).blue,
            0x99 / 255,
            accuracy: 0.01
        )
        XCTAssertEqual(
            try components(XCTUnwrap(textView.editorSelectionColor), appearance: .aqua).green,
            0x55 / 255,
            accuracy: 0.01
        )
        let gutter = try XCTUnwrap(textView.lineNumberGutter)
        XCTAssertEqual(
            try components(XCTUnwrap(gutter.style.backgroundColor), appearance: .aqua).green,
            0xBB / 255,
            accuracy: 0.01
        )
    }

    func testCustomHighlightUsesTheImportedTextColor() async throws {
        let document = try CustomThemeValidation.validate(Data("""
        {
          "schemaVersion": 1,
          "id": "ink",
          "name": "Ink",
          "light": {"editor": {"text": "#FF0000"}},
          "dark": {"editor": {"text": "#00FF00"}}
        }
        """.utf8)).get()
        let service = MarkdownHighlightService()
        let highlighted = await service.highlight(
            "Hello",
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: 5),
            theme: .standard,
            customTheme: document,
            fontName: MarkdownSyntaxHighlighter.systemMonospacedFontName,
            fontSize: 13
        )
        let color = try XCTUnwrap(
            NSAttributedString(highlighted.text).attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        )
        XCTAssertEqual(components(color, appearance: .aqua).red, 1, accuracy: 0.01)
        XCTAssertEqual(components(color, appearance: .aqua).green, 0, accuracy: 0.01)
        XCTAssertEqual(components(color, appearance: .darkAqua).green, 1, accuracy: 0.01)
        XCTAssertEqual(components(color, appearance: .darkAqua).red, 0, accuracy: 0.01)
    }

    func testApplyingTheSameHighlightAttributesDoesNotEditThemAgain() throws {
        let source = "Hello"
        let scrollView = MarkdownSTTextView.scrollableTextView()
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = source
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: textView))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: MarkdownSyntaxHighlighter.defaultFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let highlighted = HighlightedText(
            revision: 1,
            text: AttributedString(NSAttributedString(string: source, attributes: attributes))
        )
        let probe = AttributeEditProbe()
        storage.delegate = probe

        XCTAssertTrue(MarkdownTextView.applyHighlightedText(highlighted, to: textView))
        let firstEdits = probe.attributeEdits
        XCTAssertGreaterThan(firstEdits, 0)

        XCTAssertTrue(MarkdownTextView.applyHighlightedText(highlighted, to: textView))
        XCTAssertEqual(probe.attributeEdits, firstEdits)
        XCTAssertEqual(textView.text, source)
    }

    func testCustomSelectionColorSurvivesTheSystemHighlightReset() throws {
        let source = "Selection stays custom."
        var text = source
        var selection: NSRange? = NSRange(location: 0, length: 9)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let selectionBinding = Binding(get: { selection }, set: { selection = $0 })
        let frame = NSRect(x: 0, y: 0, width: 560, height: 180)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        let coordinator = MarkdownTextView(
            text: textBinding,
            styledText: nil,
            selection: selectionBinding,
            showsLineNumbers: false
        ).makeCoordinator()
        textView.textDelegate = coordinator
        let window = EditorFindControllerTestSupport.registerWindowForTeardown(NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        ))
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        textView.text = source
        window.makeFirstResponder(textView)
        textView.textSelection = NSRange(location: 0, length: 9)

        let custom = try CustomThemeValidation.validate(Data("""
        {"schemaVersion":1,"id":"ink","name":"Ink","light":{"editor":{"selection":"#224466"}}}
        """.utf8)).get()
        let themed = MarkdownTextView(
            text: textBinding,
            styledText: nil,
            selection: selectionBinding,
            showsLineNumbers: false,
            syntaxTheme: MarkdownSyntaxTheme.resolving(custom)
        )
        themed.updateRepresentedTextView(scrollView, coordinator: coordinator)
        textView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let scans = textView.selectionHighlightTreeScans
        XCTAssertGreaterThan(scans, 0)
        textView.layout()
        XCTAssertEqual(
            textView.selectionHighlightTreeScans,
            scans,
            "layout repaints the selection container, not the document"
        )

        let highlight = try XCTUnwrap(selectionHighlight(in: textView))
        let locked = try XCTUnwrap(highlight.layer?.backgroundColor)
        highlight.layer?.backgroundColor = NSColor.systemRed.cgColor
        XCTAssertEqual(highlight.layer?.backgroundColor, locked)

        let builtIn = MarkdownTextView(
            text: textBinding,
            styledText: nil,
            selection: selectionBinding,
            showsLineNumbers: false,
            syntaxTheme: .standard
        )
        builtIn.updateRepresentedTextView(scrollView, coordinator: coordinator)
        textView.layoutSubtreeIfNeeded()
        highlight.layer?.backgroundColor = NSColor.systemRed.cgColor
        XCTAssertNotEqual(highlight.layer?.backgroundColor, locked)
    }

    func testIncreaseContrastAndFallbackIdentityDoNotShareANamedColor() throws {
        let previous = EditorThemeDynamicColor.increaseContrastEnabled
        defer { EditorThemeDynamicColor.increaseContrastEnabled = previous }
        // Light text is custom. Light code is omitted, so each fallback must keep its own
        // built-in code color. Dark code is set only to force a named color for that slot.
        let document = try CustomThemeValidation.validate(Data("""
        {
          "schemaVersion": 1,
          "id": "ink",
          "name": "Ink",
          "light": {"editor": {"text": "#112233"}},
          "dark": {"editor": {"code": "#445566"}}
        }
        """.utf8)).get()

        EditorThemeDynamicColor.increaseContrastEnabled = { false }
        let standard = MarkdownSyntaxTheme.resolving(document, builtIn: .standard)
        let graphite = MarkdownSyntaxTheme.resolving(document, builtIn: .graphite)
        let standardCode = components(standard.codeColor, appearance: .aqua)
        let graphiteCode = components(graphite.codeColor, appearance: .aqua)
        let standardBuiltIn = components(MarkdownSyntaxTheme.standard.codeColor, appearance: .aqua)
        let graphiteBuiltIn = components(MarkdownSyntaxTheme.graphite.codeColor, appearance: .aqua)
        XCTAssertEqual(standardCode.red, standardBuiltIn.red, accuracy: 0.02)
        XCTAssertEqual(standardCode.green, standardBuiltIn.green, accuracy: 0.02)
        XCTAssertEqual(standardCode.blue, standardBuiltIn.blue, accuracy: 0.02)
        XCTAssertEqual(graphiteCode.red, graphiteBuiltIn.red, accuracy: 0.02)
        XCTAssertEqual(graphiteCode.green, graphiteBuiltIn.green, accuracy: 0.02)
        XCTAssertEqual(graphiteCode.blue, graphiteBuiltIn.blue, accuracy: 0.02)
        let distinct = abs(standardCode.red - graphiteCode.red) > 0.05
            || abs(standardCode.green - graphiteCode.green) > 0.05
            || abs(standardCode.blue - graphiteCode.blue) > 0.05
        XCTAssertTrue(distinct, "omitted code color must follow its own built-in fallback")

        EditorThemeDynamicColor.increaseContrastEnabled = { true }
        let contrastedText = components(standard.textColor, appearance: .aqua)
        let builtInText = components(MarkdownSyntaxTheme.standard.textColor, appearance: .aqua)
        XCTAssertEqual(contrastedText.red, builtInText.red, accuracy: 0.02)
        XCTAssertEqual(contrastedText.green, builtInText.green, accuracy: 0.02)
        XCTAssertEqual(contrastedText.blue, builtInText.blue, accuracy: 0.02)

        // The provider registered above follows the setting. A new name is not required.
        EditorThemeDynamicColor.increaseContrastEnabled = { false }
        XCTAssertEqual(components(standard.textColor, appearance: .aqua).red, 0x11 / 255, accuracy: 0.01)
    }

    func testHighlightReusesTheResolvedThemeUntilTheDocumentChanges() async throws {
        let document = try CustomThemeValidation.validate(Data("""
        {"schemaVersion":1,"id":"ink","name":"Ink","light":{"editor":{"text":"#FF0000"}}}
        """.utf8)).get()
        let previous = EditorThemeResolutionProbe.count
        defer { EditorThemeResolutionProbe.count = previous }
        EditorThemeResolutionProbe.count = 0
        let service = MarkdownHighlightService()
        for _ in 0 ..< 2 {
            _ = await service.highlight(
                "Hello",
                fileKind: .markdown,
                visibleRange: NSRange(location: 0, length: 5),
                theme: .standard,
                customTheme: document,
                fontName: MarkdownSyntaxHighlighter.systemMonospacedFontName,
                fontSize: 13
            )
        }
        XCTAssertEqual(EditorThemeResolutionProbe.count, 1)
    }

    private func selectionHighlight(in view: NSView) -> NSView? {
        if String(describing: type(of: view)) == "STSelectionHighlightView" {
            return view
        }
        for subview in view.subviews {
            if let found = selectionHighlight(in: subview) {
                return found
            }
        }
        return nil
    }

    private func components(_ color: NSColor,
                            appearance name: NSAppearance.Name) -> (red: CGFloat, green: CGFloat, blue: CGFloat)
    {
        guard let drawingAppearance = NSAppearance(named: name) else {
            return (0, 0, 0)
        }
        var resolved = color
        drawingAppearance.performAsCurrentDrawingAppearance {
            guard let converted = color.cgColor.converted(
                to: CGColorSpaceCreateDeviceRGB(),
                intent: .defaultIntent,
                options: nil
            ), let matched = NSColor(cgColor: converted)?.usingColorSpace(.sRGB) else {
                return
            }
            resolved = matched
        }
        return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
    }
}

private final class AttributeEditProbe: NSObject, NSTextStorageDelegate {
    var attributeEdits = 0

    func textStorage(
        _: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range _: NSRange,
        changeInLength _: Int
    ) {
        if editedMask.contains(.editedAttributes) {
            attributeEdits += 1
        }
    }
}
