import AppKit
import EditorKit
import Foundation
import MarkdownCore

struct EditorThemeChoice: Identifiable, Equatable {
    var id: String
    var name: String
}

extension PlainsongPreferences {
    func selectEditorTheme(identifier: String) {
        if let builtIn = MarkdownEditorTheme(rawValue: identifier) {
            setEditorTheme(builtIn)
            return
        }
        guard editorThemeIdentifier != identifier else { return }
        guard let document = importedEditorThemes.first(where: { $0.id == identifier }) else { return }
        editorTheme = .standard
        editorThemeIdentifier = identifier
        resolvedEditorSyntaxTheme = MarkdownSyntaxTheme.resolving(document)
        editorThemeFallbackNotice = nil
        editorThemeRevision &+= 1
        userDefaults.set(identifier, forKey: Keys.editorTheme)
        notifyDidChange()
    }

    @discardableResult
    func importEditorTheme(from url: URL) throws -> EditorThemeImportResult {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try themeData(at: url)
        let result = try editorThemeLibrary.importTheme(data: data) { document in
            confirmEditorThemeReplacement(document.id, document.name)
        }
        if case let .imported(document) = result {
            reloadImportedEditorThemes()
            editorTheme = .standard
            editorThemeIdentifier = document.id
            resolvedEditorSyntaxTheme = MarkdownSyntaxTheme.resolving(document)
            editorThemeFallbackNotice = nil
            editorThemeRevision &+= 1
            userDefaults.set(document.id, forKey: Keys.editorTheme)
            notifyDidChange()
        }
        return result
    }

    func revealSelectedEditorTheme() {
        guard let url = editorThemeLibrary.existingFileURL(identifier: editorThemeIdentifier) else { return }
        revealEditorThemeFile(url)
    }

    @discardableResult
    func removeSelectedEditorTheme() throws -> URL {
        let identifier = editorThemeIdentifier
        let trashed = try editorThemeLibrary.moveToTrash(identifier: identifier)
        reloadImportedEditorThemes()
        setEditorTheme(.standard)
        return trashed
    }

    func dismissEditorThemeFallbackNotice() {
        guard editorThemeFallbackNotice != nil else { return }
        editorThemeFallbackNotice = nil
        notifyDidChange()
    }

    var canManageSelectedEditorThemeFile: Bool {
        MarkdownEditorTheme(rawValue: editorThemeIdentifier) == nil
            && editorThemeLibrary.existingFileURL(identifier: editorThemeIdentifier) != nil
    }

    /// The imported document for the selected id, or nil for a built-in or a file that
    /// failed validation. Highlighting reads this instead of `NSColor`, which is not Sendable.
    var selectedCustomEditorTheme: CustomThemeDocument? {
        guard MarkdownEditorTheme(rawValue: editorThemeIdentifier) == nil else { return nil }
        return importedEditorThemes.first { $0.id == editorThemeIdentifier }
    }

    var editorThemePickerChoices: [EditorThemeChoice] {
        var choices = MarkdownEditorTheme.allCases.map {
            EditorThemeChoice(id: $0.rawValue, name: $0.displayName)
        }
        choices += importedEditorThemes
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { EditorThemeChoice(id: $0.id, name: $0.name) }
        if !choices.contains(where: { $0.id == editorThemeIdentifier }) {
            choices.append(EditorThemeChoice(
                id: editorThemeIdentifier,
                name: "\(editorThemeIdentifier) (unavailable)"
            ))
        }
        return choices
    }

    func reloadImportedEditorThemes() {
        importedEditorThemes = editorThemeLibrary.loadCatalog().themes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func editorThemeFallbackNotice(for identifier: String) -> String {
        """
        The editor theme \"\(identifier)\" could not be read. Plainsong is using the built-in \
        theme for this launch, and the saved selection was kept.
        """
    }

    private func themeData(at url: URL) throws -> Data {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        } catch {
            throw EditorThemeStoreError.unreadable
        }
        guard values.isRegularFile != false else {
            throw EditorThemeStoreError.unreadable
        }
        if let fileSize = values.fileSize, fileSize > CustomThemeDocument.maximumByteCount {
            throw EditorThemeStoreError.invalid(.exceedsMaximumSize(byteCount: fileSize))
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw EditorThemeStoreError.unreadable
        }
    }
}

struct StoredEditorTheme {
    var themes: [CustomThemeDocument]
    var identifier: String
    var theme: MarkdownEditorTheme
    var syntaxTheme: MarkdownSyntaxTheme
    var notice: String?

    @MainActor
    static func load(library: EditorThemeLibrary, identifier storedIdentifier: String?) -> StoredEditorTheme {
        let catalog = library.loadCatalog()
        let themes = catalog.themes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let identifier = storedIdentifier ?? MarkdownEditorTheme.standard.rawValue
        if let builtIn = MarkdownEditorTheme(rawValue: identifier) {
            return StoredEditorTheme(
                themes: themes,
                identifier: identifier,
                theme: builtIn,
                syntaxTheme: .builtIn(builtIn),
                notice: nil
            )
        }
        if let custom = catalog.theme(identifier: identifier) {
            return StoredEditorTheme(
                themes: themes,
                identifier: identifier,
                theme: .standard,
                syntaxTheme: .resolving(custom),
                notice: nil
            )
        }
        return StoredEditorTheme(
            themes: themes,
            identifier: identifier,
            theme: .standard,
            syntaxTheme: .standard,
            notice: PlainsongPreferences.editorThemeFallbackNotice(for: identifier)
        )
    }
}
