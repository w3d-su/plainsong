import Combine
import Foundation

/// A full-source transition prepared away from the main actor.
///
/// The destination source, literal equality result, and statistics stay together so a
/// caller cannot accidentally apply metadata computed for different text. A session
/// accepts the transition only while it is still at `sourceRevision`.
public struct DocumentSessionTextTransition: Sendable {
    fileprivate let sourceRevision: Int
    fileprivate let destinationText: String
    fileprivate let destinationDiffers: Bool
    fileprivate let destinationStatistics: TextStatistics

    public var changesText: Bool {
        destinationDiffers
    }

    public init(
        sourceText: String,
        sourceRevision: Int,
        destinationText: String
    ) {
        self.sourceRevision = sourceRevision
        self.destinationText = destinationText
        destinationDiffers = !ExactSourceText.matches(sourceText, destinationText)
        destinationStatistics = TextStatistics(text: destinationText)
    }
}

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
    /// Nil while a newly opened file is being counted. Views should read this value.
    @Published public private(set) var availableStatistics: TextStatistics?
    /// A deferred edit can outlive its editor. A new attachment must finish that count.
    public private(set) var needsStatisticsRefresh = false

    /// Callers that require counts synchronously can still obtain them during opening.
    public var statistics: TextStatistics {
        availableStatistics ?? TextStatistics(text: text)
    }

    private(set) var statisticsTask: Task<Void, Never>?

    private var savedText: String?
    private var textChangeContinuations: [UUID: AsyncStream<DocumentTextChange>.Continuation] = [:]

    public var snapshot: DocumentSnapshot {
        DocumentSnapshot(
            text: text,
            version: version,
            fileKind: fileKind,
            fileURL: fileURL,
            isDirty: isDirty,
            statistics: availableStatistics
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

    public convenience init(
        text: String = "",
        url: URL? = nil,
        fileKind: FileKind? = nil,
        isDirty: Bool = false
    ) {
        self.init(text: text, url: url, fileKind: fileKind, isDirty: isDirty, statistics: TextStatistics(text: text))
    }

    /// Small documents have immediate counts. Opening a large document installs the editable
    /// source first. The worker belongs to this session, including across window switches.
    public convenience init(
        opening text: String,
        url: URL,
        fileKind: FileKind,
        onStatisticsReady: (@MainActor (DocumentSession) -> Void)? = nil
    ) {
        guard text.utf8.count >= 64 * 1024 else {
            self.init(text: text, url: url, fileKind: fileKind)
            return
        }
        self.init(text: text, url: url, fileKind: fileKind, isDirty: false, statistics: nil)
        scheduleStatisticsCount(debounced: false, onReady: onStatisticsReady)
    }

    /// Count the most recent edit after a typing pause. The work follows this session
    /// through window switches and URL changes. Only a source change invalidates it.
    public func scheduleStatisticsRefreshAfterEdit() {
        scheduleStatisticsCount(debounced: true)
    }

    private func scheduleStatisticsCount(
        debounced: Bool,
        onReady: (@MainActor (DocumentSession) -> Void)? = nil
    ) {
        cancelStatisticsTask()
        let source = text
        statisticsTask = Task.detached(priority: .utility) { [weak self] in
            if debounced {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard let counts = TextStatistics.countUnlessCancelled(source) else { return }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self else { return }
                statisticsTask = nil
                applyStatistics(counts)
                onReady?(self)
            }
        }
    }

    deinit {
        statisticsTask?.cancel()
    }

    private init(text: String, url: URL?, fileKind: FileKind?, isDirty: Bool, statistics: TextStatistics?) {
        self.text = text
        version = 0
        fileURL = url
        self.fileKind = fileKind ?? url.flatMap(FileKind.init(url:)) ?? .markdown
        self.isDirty = isDirty
        availableStatistics = statistics
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

        cancelStatisticsTask()
        text = newText
        if refreshStatistics {
            self.refreshStatistics()
        } else {
            needsStatisticsRefresh = true
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

    /// Applies a literal source mutation already authorized by the App-owned editor
    /// revision fence. Authorization does not weaken the session invariants: an exact
    /// no-op stays a no-op, and returning to the persisted baseline becomes clean.
    public func replaceTextFromAuthorizedEditor(
        _ newText: String,
        refreshStatistics: Bool = true
    ) {
        replaceText(newText, refreshStatistics: refreshStatistics)
    }

    public func refreshStatistics() {
        applyStatistics(TextStatistics(text: text))
    }

    /// Applies statistics computed elsewhere (e.g. on a background task — counting a
    /// large document is O(n) and must stay off the typing hot path).
    public func applyStatistics(_ newStatistics: TextStatistics) {
        cancelStatisticsTask()
        needsStatisticsRefresh = false
        if availableStatistics != newStatistics {
            availableStatistics = newStatistics
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

    /// Replaces the persisted-text baseline without changing the editor's current text.
    ///
    /// External-change arbitration uses this after proving a newer disk version: the editor
    /// keeps the user's local bytes, while subsequent edits become clean only when they exactly
    /// match the newly observed disk bytes.
    public func rebaseSavedText(to newSavedText: String) {
        savedText = newSavedText
        let newIsDirty = !ExactSourceText.matches(newSavedText, text)
        if isDirty != newIsDirty {
            isDirty = newIsDirty
        }
    }

    /// Retargets the session after an authority-safe filesystem relocation.
    ///
    /// Relocation changes only the document identity presented to consumers. The current
    /// source and persisted baseline stay intact, so an already-dirty session remains dirty
    /// and a clean session remains clean while Markdown/MDX presentation follows the new name.
    public func relocate(to newURL: URL) {
        applyState(
            text: text,
            url: newURL,
            fileKind: FileKind(url: newURL) ?? fileKind,
            isDirty: isDirty
        )
    }

    /// Replaces the full session state when opening or restoring a document.
    public func reset(
        text newText: String,
        url newURL: URL?,
        fileKind newFileKind: FileKind,
        isDirty newIsDirty: Bool,
        statistics precomputedStatistics: TextStatistics? = nil
    ) {
        applyState(
            text: newText,
            url: newURL,
            fileKind: newFileKind,
            isDirty: newIsDirty,
            statistics: precomputedStatistics
        )
        savedText = newIsDirty ? nil : newText
    }

    /// Applies a transition whose literal comparison and statistics were computed away
    /// from the main actor. Returns `false` if the session changed after preparation.
    @discardableResult
    public func reset(
        precomputedTextTransition transition: DocumentSessionTextTransition,
        url newURL: URL?,
        fileKind newFileKind: FileKind,
        isDirty newIsDirty: Bool
    ) -> Bool {
        guard version == transition.sourceRevision else { return false }
        applyState(
            text: transition.destinationText,
            url: newURL,
            fileKind: newFileKind,
            isDirty: newIsDirty,
            statistics: transition.destinationStatistics,
            knownTextChanged: transition.destinationDiffers
        )
        savedText = newIsDirty ? nil : transition.destinationText
        return true
    }

    private func applyState(
        text newText: String,
        url newURL: URL?,
        fileKind newFileKind: FileKind,
        isDirty newIsDirty: Bool,
        statistics precomputedStatistics: TextStatistics? = nil,
        knownTextChanged: Bool? = nil
    ) {
        let textChanged = knownTextChanged ?? !ExactSourceText.matches(text, newText)
        let renderableStateChanged = textChanged || fileURL != newURL || fileKind != newFileKind
        if renderableStateChanged {
            version += 1
        }

        if textChanged {
            let counts = precomputedStatistics ?? TextStatistics(text: newText)
            // A full reload must still invalidate observers when its text changes but
            // all published metadata (including counts) would otherwise stay equal.
            if availableStatistics == counts, fileURL == newURL, fileKind == newFileKind, isDirty == newIsDirty {
                objectWillChange.send()
            }
            text = newText
            applyStatistics(counts)
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

    private func cancelStatisticsTask() {
        statisticsTask?.cancel()
        statisticsTask = nil
    }

    private func emitTextChange() {
        let change = currentTextChange
        for continuation in textChangeContinuations.values {
            continuation.yield(change)
        }
    }
}
