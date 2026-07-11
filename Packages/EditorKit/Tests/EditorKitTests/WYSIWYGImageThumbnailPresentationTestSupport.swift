import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

actor TestEditorImageThumbnailLoader: EditorImageThumbnailLoading {
    struct Request: Equatable {
        let rootURL: URL
        let documentDirectoryRelativePath: String
        let source: String
        let maxPixelSize: Int
    }

    private var outcomes: [String: EditorImageThumbnailOutcome]
    private var delayNanoseconds: UInt64
    private var requests: [Request] = []

    init(
        outcomes: [String: EditorImageThumbnailOutcome],
        delayNanoseconds: UInt64 = 0
    ) {
        self.outcomes = outcomes
        self.delayNanoseconds = delayNanoseconds
    }

    func loadThumbnail(
        rootURL: URL,
        documentDirectoryRelativePath: String,
        source: String,
        maxPixelSize: Int
    ) async -> EditorImageThumbnailOutcome {
        requests.append(Request(
            rootURL: rootURL,
            documentDirectoryRelativePath: documentDirectoryRelativePath,
            source: source,
            maxPixelSize: maxPixelSize
        ))
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return outcomes[source] ?? .failed(.missingFile)
    }

    func setOutcome(_ outcome: EditorImageThumbnailOutcome, for source: String) {
        outcomes[source] = outcome
    }

    func setDelayNanoseconds(_ delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func recordedRequests() -> [Request] {
        requests
    }
}

@MainActor
extension WYSIWYGImageThumbnailPresentationTests {
    struct WindowedEditor {
        let window: NSWindow
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
        let loader: TestEditorImageThumbnailLoader
        let configuration: EditorImageThumbnailConfiguration
    }

    static var imageRange: NSRange {
        let range = (source as NSString).range(of: imageSource)
        precondition(range.location != NSNotFound)
        return range
    }

    func makeWindowedEditor(
        source: String? = nil,
        selection: NSRange = NSRange(location: 0, length: 0),
        frame: NSRect = NSRect(x: 0, y: 0, width: 760, height: 420),
        outcomes: [String: EditorImageThumbnailOutcome]? = nil,
        delayNanoseconds: UInt64 = 0,
        linkFoldingEnabled: Bool = true,
        refreshProxy: EditorImageThumbnailRefreshProxy? = nil
    ) throws -> WindowedEditor {
        let source = source ?? Self.source
        let defaultOutcome = Self.readyOutcome(
            source: "fixture.png",
            resolvedPath: "posts/fixture.png"
        )
        let loader = TestEditorImageThumbnailLoader(
            outcomes: outcomes ?? ["fixture.png": defaultOutcome],
            delayNanoseconds: delayNanoseconds
        )
        let configuration = EditorImageThumbnailConfiguration(
            loader: loader,
            rootURL: URL(fileURLWithPath: "/tmp/PlainsongImageThumbnailTests", isDirectory: true),
            documentDirectoryRelativePath: "posts",
            refreshProxy: refreshProxy
        )

        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.showsLineNumbers = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        textView.textSelection = selection
        let coordinator = MarkdownTextViewCoordinator(
            text: .constant(source),
            selection: .constant(selection)
        )
        textView.textDelegate = coordinator
        XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true))
        coordinator.updateImageThumbnailPresentationConfiguration(
            configuration,
            documentIdentity: EditorDocumentIdentity(rawValue: "test-document"),
            isPresentationEnabled: true,
            in: textView
        )

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
        applyPresentation(
            source: source,
            selection: selection,
            linkFoldingEnabled: linkFoldingEnabled,
            coordinator: coordinator,
            textView: textView
        )
        ensureLayout(in: textView)
        return WindowedEditor(
            window: window,
            textView: textView,
            coordinator: coordinator,
            loader: loader,
            configuration: configuration
        )
    }

    func applyPresentation(
        source: String,
        selection: NSRange,
        linkFoldingEnabled: Bool = true,
        coordinator: MarkdownTextViewCoordinator,
        textView: MarkdownSTTextView
    ) {
        textView.textSelection = selection
        let presentation: MarkdownEditorDevelopmentPresentation = linkFoldingEnabled
            ? .inlineFoldRevealWithLinkFolding
            : .inlineFoldReveal
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: presentation,
            selection: selection
        )
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            HighlightedText(
                revision: 1,
                range: highlighted.range,
                text: highlighted.text,
                foldPlan: highlighted.foldPlan
            ),
            to: textView
        ))
        coordinator.applyImageThumbnailPresentation(
            foldPlan: highlighted.foldPlan,
            in: textView,
            forceReapply: true
        )
    }

    func waitForMarker(
        in textView: MarkdownSTTextView,
        range: NSRange,
        matching predicate: @escaping (WYSIWYGImagePresentationMarker) -> Bool = { _ in true },
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws -> WYSIWYGImagePresentationMarker {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if let marker = imageMarker(in: textView, range: range), predicate(marker) {
                return marker
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for image presentation marker")
        throw TestError.timeout
    }

    func waitForRequestCount(
        _ expectedCount: Int,
        loader: TestEditorImageThumbnailLoader,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if await loader.recordedRequests().count >= expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(expectedCount) thumbnail requests")
        throw TestError.timeout
    }

    func imageMarker(
        in textView: MarkdownSTTextView,
        range: NSRange
    ) -> WYSIWYGImagePresentationMarker? {
        guard let textStorage = MarkdownTextView.textStorage(of: textView),
              range.location >= 0,
              range.location < textStorage.length
        else {
            return nil
        }
        return textStorage.attribute(
            WYSIWYGImagePresentationMarker.attribute,
            at: range.location,
            effectiveRange: nil
        ) as? WYSIWYGImagePresentationMarker
    }

    @discardableResult
    func assertLiveAttachment(
        in textView: STTextView,
        imageRange: NSRange,
        expectedSize: NSSize? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSTextLineFragment {
        ensureLayout(in: textView)
        let projectedLine = try lineFragment(containing: imageRange, in: textView)
        let projectedLineContents = projectedLine.attributedString.attributedSubstring(
            from: projectedLine.characterRange
        )
        XCTAssertEqual(
            projectedLineContents.string.unicodeScalars.filter { $0.value == 0xFFFC }.count,
            1,
            "Expected one live projected attachment character",
            file: file,
            line: line
        )
        let objectRange = (projectedLineContents.string as NSString).range(of: "\u{FFFC}")
        XCTAssertNotEqual(objectRange.location, NSNotFound, file: file, line: line)
        if objectRange.location != NSNotFound {
            let attachment = projectedLineContents.attribute(
                .attachment,
                at: objectRange.location,
                effectiveRange: nil
            ) as? NSTextAttachment
            XCTAssertNotNil(attachment, file: file, line: line)
            if let attachment, let expectedSize {
                XCTAssertEqual(attachment.bounds.size, expectedSize, file: file, line: line)
                XCTAssertEqual(attachment.image?.size, expectedSize, file: file, line: line)
            }
        }
        return projectedLine
    }

    func clickAttachment(in fixture: WindowedEditor, imageRange: NSRange) throws -> Int {
        _ = try assertLiveAttachment(in: fixture.textView, imageRange: imageRange)
        let attachmentRect = try lineFragmentFrame(containing: imageRange, in: fixture.textView)
        let windowPoint = fixture.textView.convert(
            CGPoint(x: attachmentRect.midX, y: attachmentRect.midY),
            to: nil
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        fixture.textView.mouseDown(with: event)
        return fixture.textView.selectedRange().location
    }

    func projectedImageParagraph(
        in textView: MarkdownSTTextView,
        imageRange: NSRange
    ) throws -> (NSTextParagraph, NSRange) {
        let textContentStorage = try XCTUnwrap(textView.textContentManager as? NSTextContentStorage)
        let delegate = try XCTUnwrap(
            textContentStorage.delegate as? WYSIWYGZeroWidthTextContentStorageDelegate
        )
        let paragraphRange = (textContentStorage.textStorage?.string as NSString?)?
            .paragraphRange(for: imageRange) ?? imageRange
        let paragraph = try XCTUnwrap(
            delegate.textContentStorage(textContentStorage, textParagraphWith: paragraphRange)
        )
        return (paragraph, paragraphRange)
    }

    func ensureLayout(in textView: STTextView) {
        textView.textLayoutManager.ensureLayout(for: textView.textLayoutManager.documentRange)
        textView.layoutSubtreeIfNeeded()
    }

    func lineFragmentFrame(containing range: NSRange, in textView: STTextView) throws -> CGRect {
        try lineFragment(containing: range, in: textView).typographicBounds.offsetBy(
            dx: layoutFragment(containing: range, in: textView).layoutFragmentFrame.minX,
            dy: layoutFragment(containing: range, in: textView).layoutFragmentFrame.minY
        )
    }

    func lineFragment(containing range: NSRange, in textView: STTextView) throws -> NSTextLineFragment {
        let fragment = try layoutFragment(containing: range, in: textView)
        let elementRange = NSRange(fragment.rangeInElement, in: textView.textContentManager)
        return try XCTUnwrap(fragment.textLineFragments.first { lineFragment in
            let lineRange = NSRange(
                location: elementRange.location + lineFragment.characterRange.location,
                length: lineFragment.characterRange.length
            )
            return NSLocationInRange(range.location, lineRange)
        })
    }

    func layoutFragment(containing range: NSRange, in textView: STTextView) throws -> NSTextLayoutFragment {
        ensureLayout(in: textView)
        let textRange = try XCTUnwrap(NSTextRange(range, in: textView.textContentManager))
        return try XCTUnwrap(textView.textLayoutManager.textLayoutFragment(for: textRange.location))
    }

    func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PlainsongImagePresentation.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }

    static func readyOutcome(
        source _: String,
        resolvedPath: String,
        pixelWidth: Int = 320,
        pixelHeight: Int = 180,
        modificationDate: Date = Date(timeIntervalSinceReferenceDate: 1)
    ) -> EditorImageThumbnailOutcome {
        .ready(EditorImageThumbnail(
            pngData: validPNGData,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            resolvedWorkspaceRelativePath: resolvedPath,
            contentModificationDate: modificationDate
        ))
    }

    static func imageRegion(in source: String, literal: String) -> MarkdownInlineImageRegion {
        let storage = source as NSString
        let sourceRange = storage.range(of: literal)
        precondition(sourceRange.location != NSNotFound)
        let altTextRange = storage.range(of: "alt", options: [], range: sourceRange)
        let sourcePathRange = storage.range(of: "fixture.png", options: [], range: sourceRange)
        guard let region = MarkdownInlineImageRegion(
            in: source,
            sourceRange: sourceRange,
            altTextRange: altTextRange,
            sourcePathRange: sourcePathRange
        ) else {
            preconditionFailure("Could not build test image region")
        }
        return region
    }

    private static var validPNGData: Data {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { bounds in
            NSColor.systemOrange.setFill()
            NSBezierPath(rect: bounds).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            preconditionFailure("Could not make test PNG")
        }
        return data
    }

    enum TestError: Error {
        case timeout
    }
}
