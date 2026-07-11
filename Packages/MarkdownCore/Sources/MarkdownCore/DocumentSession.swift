import Combine
import Foundation

/// Main-actor document model for one editable Markdown or MDX file.
@MainActor
public final class DocumentSession: ObservableObject {
    /// Deliberately NOT `@Published`: `text` and `version` change on every keystroke,
    /// and publishing them re-rendered the whole window per key press (visible in
    /// Time Profiler as SwiftUI DynamicBody work inside `keyDown`). The editor is the
    /// source of truth while typing; UI-relevant state below stays published and
    /// changes rarely. M2's preview should consume text via its own debounced
    /// subscription, not via objectWillChange.
    public private(set) var text: String
    public private(set) var version: Int

    @Published public private(set) var fileURL: URL?
    @Published public private(set) var fileKind: FileKind
    @Published public private(set) var isDirty: Bool
    @Published public private(set) var statistics: TextStatistics

    private var savedText: String?
    private var textChangeContinuations: [UUID: AsyncStream<DocumentTextChange>.Continuation] = [:]

    public var snapshot: DocumentSnapshot {
        DocumentSnapshot(
            text: text,
            version: version,
            fileKind: fileKind,
            fileURL: fileURL,
            isDirty: isDirty,
            statistics: statistics
        )
    }

    public var currentTextChange: DocumentTextChange {
        DocumentTextChange(
            text: text,
            version: version,
            fileKind: fileKind,
            fileURL: fileURL
        )
    }

    public init(
        text: String = "",
        url: URL? = nil,
        fileKind: FileKind? = nil,
        isDirty: Bool = false
    ) {
        self.text = text
        version = 0
        fileURL = url
        self.fileKind = fileKind ?? url.flatMap(FileKind.init(url:)) ?? .markdown
        self.isDirty = isDirty
        statistics = TextStatistics(text: text)
        savedText = isDirty ? nil : text
    }

    /// Explicit preview channel for high-frequency text/version changes.
    ///
    /// Consumers should debounce this stream themselves (M2 uses ~150 ms) and drop
    /// stale renders by `version`. This deliberately does not call `objectWillChange`.
    public func textChanges(includeCurrent: Bool = true) -> AsyncStream<DocumentTextChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            textChangeContinuations[id] = continuation

            if includeCurrent {
                continuation.yield(currentTextChange)
            }

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.textChangeContinuations[id] = nil
                }
            }
        }
    }

    /// Applies editor text replacement. Literally identical text is a no-op to avoid false versions.
    public func replaceText(_ newText: String, refreshStatistics: Bool = true) {
        guard !ExactSourceText.matches(newText, text) else {
            return
        }

        text = newText
        if refreshStatistics {
            self.refreshStatistics()
        }
        // Dedupe the assignment: `isDirty` is @Published, and republishing the same
        // value on every keystroke would re-render observers needlessly.
        let newIsDirty = savedText.map { !ExactSourceText.matches($0, newText) } ?? true
        if isDirty != newIsDirty {
            isDirty = newIsDirty
        }
        version += 1
        emitTextChange()
    }

    public func refreshStatistics() {
        applyStatistics(TextStatistics(text: text))
    }

    /// Applies statistics computed elsewhere (e.g. on a background task — counting a
    /// large document is O(n) and must stay off the typing hot path).
    public func applyStatistics(_ newStatistics: TextStatistics) {
        if statistics != newStatistics {
            statistics = newStatistics
        }
    }

    /// Marks the provided text and URL as persisted.
    public func markSaved(text savedText: String, url savedURL: URL?) {
        let savedFileKind = savedURL.flatMap(FileKind.init(url:)) ?? fileKind
        applyState(
            text: savedText,
            url: savedURL,
            fileKind: savedFileKind,
            isDirty: false
        )
        self.savedText = savedText
    }

    /// Replaces the full session state when opening or restoring a document.
    public func reset(
        text newText: String,
        url newURL: URL?,
        fileKind newFileKind: FileKind,
        isDirty newIsDirty: Bool
    ) {
        applyState(
            text: newText,
            url: newURL,
            fileKind: newFileKind,
            isDirty: newIsDirty
        )
        savedText = newIsDirty ? nil : newText
    }

    private func applyState(
        text newText: String,
        url newURL: URL?,
        fileKind newFileKind: FileKind,
        isDirty newIsDirty: Bool
    ) {
        let textChanged = !ExactSourceText.matches(text, newText)
        let renderableStateChanged = textChanged || fileURL != newURL || fileKind != newFileKind
        if renderableStateChanged {
            version += 1
        }

        if textChanged {
            text = newText
            statistics = TextStatistics(text: newText)
        }

        if fileURL != newURL {
            fileURL = newURL
        }

        if fileKind != newFileKind {
            fileKind = newFileKind
        }

        if isDirty != newIsDirty {
            isDirty = newIsDirty
        }

        if renderableStateChanged {
            emitTextChange()
        }
    }

    private func emitTextChange() {
        let change = currentTextChange
        for continuation in textChangeContinuations.values {
            continuation.yield(change)
        }
    }
}
