import Combine
import Foundation

/// Main-actor document model for one editable Markdown or MDX file.
@MainActor
public final class DocumentSession: ObservableObject {
    @Published public private(set) var text: String
    @Published public private(set) var version: Int
    @Published public private(set) var fileURL: URL?
    @Published public private(set) var fileKind: FileKind
    @Published public private(set) var isDirty: Bool
    @Published public private(set) var statistics: TextStatistics

    private var savedText: String?

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

    /// Applies editor text replacement. Equal text is a no-op to avoid false versions.
    public func replaceText(_ newText: String, refreshStatistics: Bool = true) {
        guard newText != text else {
            return
        }

        text = newText
        if refreshStatistics {
            self.refreshStatistics()
        }
        isDirty = savedText.map { $0 != newText } ?? true
        version += 1
    }

    public func refreshStatistics() {
        let newStatistics = TextStatistics(text: text)
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
        let renderableStateChanged = text != newText || fileURL != newURL || fileKind != newFileKind
        if renderableStateChanged {
            version += 1
        }

        if text != newText {
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
    }
}
