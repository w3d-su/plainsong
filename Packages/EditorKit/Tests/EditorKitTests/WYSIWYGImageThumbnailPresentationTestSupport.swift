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
    private(set) var loadThreadWasMain = false

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
        // Actor-isolated loader bodies run off MainActor; record via pthread for Swift 6 safety.
        loadThreadWasMain = pthread_main_np() != 0
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

    func didLoadOnMainThread() -> Bool {
        loadThreadWasMain
    }
}

/// Shared windowed-editor fixtures for image-thumbnail presentation and native-gate suites.
@MainActor
enum WYSIWYGImageThumbnailGateSupport {
    static let imageSource = "![alt](fixture.png)"
    static let source = "Top sibling line\n\(imageSource)\nBottom sibling line\n"

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

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func makeWindowedEditor(
        source: String? = nil,
        selection: NSRange = NSRange(location: 0, length: 0),
        frame: NSRect = NSRect(x: 0, y: 0, width: 760, height: 420),
        pinnedTextContainerWidth: CGFloat? = nil,
        outcomes: [String: EditorImageThumbnailOutcome]? = nil,
        delayNanoseconds: UInt64 = 0,
        linkFoldingEnabled: Bool = true,
        refreshProxy: EditorImageThumbnailRefreshProxy? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WindowedEditor {
        let source = source ?? Self.source
        let defaultOutcome = readyOutcome(
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
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView, file: file, line: line)
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
        XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true), file: file, line: line)
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
        if let pinnedTextContainerWidth {
            textView.textContainer.size.width = pinnedTextContainerWidth
            XCTAssertEqual(textView.textContainer.size.width, pinnedTextContainerWidth, file: file, line: line)
        }
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

    static func applyPresentation(
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

    static func waitForMarker(
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

    static func waitForRequestCount(
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

    static func imageMarker(
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
    static func assertLiveAttachment(
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
}
