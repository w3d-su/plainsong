import AppKit
import MarkdownCore
import SwiftUI

/// Plainsong's source editor abstraction.
///
/// STTextView stays behind this view so App and lower layers never depend on concrete
/// editor library types. The typing hot path moves plain `String` only; styling is
/// lightly debounced, computed off the main thread, and applied in place (agent.md §12).
@MainActor
public struct MarkdownEditorView: View {
    @Binding private var text: String
    @State private var styledText: HighlightedText?
    @State private var highlightRevision = 0
    @State private var selection: NSRange?
    @State private var visibleTextRange: NSRange?
    #if DEBUG
        @StateObject private var debugNavigationProbe = EditorNavigationDebugProbe.shared
    #endif
    @StateObject private var defaultCommandProxy = EditorCommandProxy()

    private static let highlightService = MarkdownHighlightService()
    nonisolated static let highlightDebounceNanoseconds: UInt64 = 20_000_000

    private let fileKind: FileKind
    private let fontName: String
    private let fontSize: CGFloat
    private let editorTheme: MarkdownEditorTheme
    private let appearanceID: String
    private let showsLineNumbers: Bool
    private let focusRequestID: Int
    private let documentIdentity: EditorDocumentIdentity?
    private let documentBindingID: EditorDocumentBindingID?
    private let onDocumentBindingLifecycle: ((EditorDocumentBindingLifecycleEvent) -> Void)?
    private let documentSourceContract: EditorDocumentSourceContract?
    private let navigationCommand: EditorNavigationCommand?
    private let scrollProxy: EditorScrollProxy?
    private let commandProxy: EditorCommandProxy?
    private let completionWorkspace: CompletionWorkspace
    private let imageAssetInserter: EditorImageAssetInserter?
    private let imageAssetContextID: String?
    private let developmentPresentation: MarkdownEditorDevelopmentPresentation
    private let developmentImageThumbnails: EditorImageThumbnailConfiguration?
    private let onWYSIWYGMechanismFailure: ((String) -> Void)?

    public init(
        text: Binding<String>,
        fileKind: FileKind,
        fontName: String = MarkdownSyntaxHighlighter.systemMonospacedFontName,
        fontSize: CGFloat = MarkdownSyntaxHighlighter.defaultFont.pointSize,
        editorTheme: MarkdownEditorTheme = .standard,
        appearanceID: String = "standard",
        showsLineNumbers: Bool = true,
        focusRequestID: Int = 0,
        documentIdentity: EditorDocumentIdentity? = nil,
        documentBindingID: EditorDocumentBindingID? = nil,
        onDocumentBindingLifecycle: ((EditorDocumentBindingLifecycleEvent) -> Void)? = nil,
        documentSourceContract: EditorDocumentSourceContract? = nil,
        navigationCommand: EditorNavigationCommand? = nil,
        scrollProxy: EditorScrollProxy? = nil,
        commandProxy: EditorCommandProxy? = nil,
        completionWorkspace: CompletionWorkspace = .empty,
        imageAssetInserter: EditorImageAssetInserter? = nil,
        imageAssetContextID: String? = nil,
        _developmentPresentation developmentPresentation: MarkdownEditorDevelopmentPresentation = .source,
        _developmentImageThumbnails developmentImageThumbnails: EditorImageThumbnailConfiguration? = nil,
        onWYSIWYGMechanismFailure: ((String) -> Void)? = nil
    ) {
        _text = text
        self.fileKind = fileKind
        self.fontName = fontName
        self.fontSize = fontSize
        self.editorTheme = editorTheme
        self.appearanceID = appearanceID
        self.showsLineNumbers = showsLineNumbers
        self.focusRequestID = focusRequestID
        self.documentIdentity = documentIdentity
        self.documentBindingID = documentBindingID
        self.onDocumentBindingLifecycle = onDocumentBindingLifecycle
        self.documentSourceContract = documentSourceContract
        self.navigationCommand = navigationCommand
        self.scrollProxy = scrollProxy
        self.commandProxy = commandProxy
        self.completionWorkspace = completionWorkspace
        self.imageAssetInserter = imageAssetInserter
        self.imageAssetContextID = imageAssetContextID
        self.developmentPresentation = developmentPresentation
        self.developmentImageThumbnails = developmentImageThumbnails
        self.onWYSIWYGMechanismFailure = onWYSIWYGMechanismFailure
    }

    public var body: some View {
        let activeCommandProxy = commandProxy ?? defaultCommandProxy

        MarkdownTextView(
            // Proxy binding: typing no longer publishes through the document model
            // (DocumentSession.text is not @Published), so the editor schedules its
            // own highlight on every user edit here. `onChange(of: text)` below still
            // covers external replacements (file open), which do re-render this view.
            // If SwiftUI also observes a local edit, the debounce/revision gate
            // collapses the duplicate request before stale parser work applies.
            text: Binding(
                get: { text },
                set: { newValue in
                    text = newValue
                    scheduleHighlight()
                }
            ),
            styledText: styledText,
            selection: $selection,
            showsLineNumbers: showsLineNumbers,
            focusRequestID: focusRequestID,
            documentIdentity: documentIdentity,
            documentBindingID: documentBindingID,
            onDocumentBindingLifecycle: onDocumentBindingLifecycle,
            documentSourceContract: documentSourceContract,
            navigationCommand: navigationCommand,
            scrollProxy: scrollProxy,
            commandProxy: activeCommandProxy,
            completionWorkspace: completionWorkspace,
            imageAssetInserter: imageAssetInserter,
            imageAssetContextID: imageAssetContextID,
            isWYSIWYGZeroWidthFoldingEnabled: developmentPresentation.enablesInlineFoldReveal,
            imageThumbnailPresentationConfiguration: developmentImageThumbnails,
            onWYSIWYGMechanismFailure: onWYSIWYGMechanismFailure,
            font: MarkdownSyntaxHighlighter.editorFont(named: fontName, size: fontSize)
        ) { range in
            Task { @MainActor in
                updateVisibleRange(range)
            }
        }
        .task(id: highlightRevision) {
            await applyScheduledVisibleHighlight(for: highlightRevision)
        }
        .onChange(of: text) { _, _ in
            scheduleHighlight()
        }
        .onChange(of: fileKind) { _, _ in
            activeCommandProxy.update(fileKind: fileKind)
            scheduleHighlight()
        }
        .onChange(of: appearanceID) { _, _ in
            scheduleHighlight()
        }
        .onChange(of: selection) { _, _ in
            guard developmentPresentation.enablesInlineFoldReveal else { return }
            scheduleHighlight()
        }
        .onAppear {
            activeCommandProxy.update(fileKind: fileKind)
            scheduleHighlight()
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
                Text("Editor navigation selection")
                    .font(.system(size: 1))
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("plainsong.debug.editor.selectedRange")
                    .accessibilityLabel("Editor UTF-16 selection \(debugAppliedSelectionValue)")
            }
        #endif
    }

    #if DEBUG
        private var debugAppliedSelectionValue: String {
            guard let observation = debugNavigationProbe.observation,
                  observation.documentIdentity == documentIdentity
            else {
                return "none"
            }
            return "\(observation.selection.location):\(observation.selection.length)"
        }
    #endif

    /// Every text, file-kind, or viewport change bumps the revision; `.task(id:)`
    /// restarts after a short debounce so rapid typing cancels stale visible-range
    /// work before it reaches the parser. Scheduling during IME composition is safe
    /// because `MarkdownTextView` blocks the apply while marked text exists.
    private func scheduleHighlight() {
        highlightRevision += 1
    }

    private func updateVisibleRange(_ range: NSRange) {
        guard visibleTextRange != range else {
            return
        }

        visibleTextRange = range
        scheduleHighlight()
    }

    private func applyScheduledVisibleHighlight(for revision: Int) async {
        guard await Self.waitForHighlightDebounce() else {
            return
        }

        await applyVisibleHighlight(for: revision)
    }

    nonisolated static func waitForHighlightDebounce(
        nanoseconds: UInt64 = highlightDebounceNanoseconds
    ) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return false
        }

        return !Task.isCancelled
    }

    private func applyVisibleHighlight(for revision: Int) async {
        guard Self.shouldApplyScheduledHighlight(
            revision: revision,
            currentRevision: highlightRevision,
            taskIsCancelled: Task.isCancelled
        ) else {
            return
        }

        let source = text
        let kind = fileKind
        let requestedRange = Self.highlightRequestRange(
            visibleRange: visibleTextRange,
            selection: selection
        )
        let highlighted = await Self.highlightService.highlight(
            source,
            fileKind: kind,
            visibleRange: requestedRange,
            theme: editorTheme,
            fontName: fontName,
            fontSize: fontSize,
            developmentPresentation: developmentPresentation,
            selection: selection
        )

        guard Self.shouldApplyScheduledHighlight(
            revision: revision,
            currentRevision: highlightRevision,
            taskIsCancelled: Task.isCancelled
        ) else {
            return
        }

        styledText = HighlightedText(
            revision: revision,
            range: highlighted.range,
            text: highlighted.text,
            foldPlan: highlighted.foldPlan
        )
    }

    nonisolated static func shouldApplyScheduledHighlight(
        revision: Int,
        currentRevision: Int,
        taskIsCancelled: Bool
    ) -> Bool {
        !taskIsCancelled && revision == currentRevision
    }

    nonisolated static func highlightRequestRange(
        visibleRange: NSRange?,
        selection: NSRange?
    ) -> NSRange {
        // Keep the debounced task's MainActor preparation independent of document
        // size. The background highlighter clamps this native viewport/selection
        // request after it has materialized the source as NSString off-main.
        if let visibleRange,
           visibleRange.location != NSNotFound,
           visibleRange.length > 0
        {
            return visibleRange
        }

        let fallbackLength = MarkdownSyntaxParser.visibleHighlightMinimumLength
        let selectionLocation = selection?.location ?? 0
        let anchor = selectionLocation == NSNotFound ? 0 : selectionLocation
        let safeAnchor = min(max(anchor, 0), Int.max - fallbackLength)
        return NSRange(location: safeAnchor, length: fallbackLength)
    }
}

extension MarkdownEditorView {
    /// Historical M1 regex bridge limit retained for regression tests and release notes.
    /// Parser-backed M1.5 highlighting runs off the main actor and does not skip large files.
    nonisolated static var maxComputedHighlightLength: Int {
        200_000
    }

    nonisolated static func shouldComputeHighlight(forLength length: Int) -> Bool {
        length >= 0
    }
}
