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
        applyEditorThemeSelection(
            identifier: identifier,
            theme: .standard,
            syntaxTheme: MarkdownSyntaxTheme.resolving(document),
            notice: nil
        )
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
            applyEditorThemeSelection(
                identifier: document.id,
                theme: .standard,
                syntaxTheme: MarkdownSyntaxTheme.resolving(document),
                notice: nil
            )
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

    func observeEditorThemeAccessibilityChanges() {
        guard editorThemeContrastObservation == nil else { return }
        editorThemeContrastObservation = EditorThemeContrastObservation { [weak self] in
            self?.reapplyEditorThemeForAccessibilityChange()
        }
    }

    /// Increase Contrast changes which built-in color a custom slot must inherit. Re-resolve
    /// so the open editor's chrome picks up the built-in colors. Highlight colors follow the
    /// same setting when AppKit resolves them; that path does not rebuild the theme per key.
    func reapplyEditorThemeForAccessibilityChange() {
        guard let document = selectedCustomEditorTheme else { return }
        applyEditorThemeSelection(
            identifier: editorThemeIdentifier,
            theme: .standard,
            syntaxTheme: MarkdownSyntaxTheme.resolving(document),
            notice: editorThemeFallbackNotice
        )
    }

    func dismissEditorThemeFallbackNotice() {
        guard editorThemeFallbackNotice != nil else { return }
        clearEditorThemeFallbackNotice()
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
        let imported = importedEditorThemes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var nameCounts: [String: Int] = [:]
        for theme in imported {
            nameCounts[editorThemeNameKey(theme.name), default: 0] += 1
        }
        let builtInNames = Set(MarkdownEditorTheme.allCases.map { editorThemeNameKey($0.displayName) })
        choices += imported.map { theme in
            let key = editorThemeNameKey(theme.name)
            let isAmbiguous = builtInNames.contains(key) || nameCounts[key, default: 0] > 1
            let name = isAmbiguous ? "\(theme.name) (\(theme.id))" : theme.name
            return EditorThemeChoice(id: theme.id, name: name)
        }
        if !choices.contains(where: { $0.id == editorThemeIdentifier }) {
            choices.append(EditorThemeChoice(
                id: editorThemeIdentifier,
                name: "\(editorThemeIdentifier) (unavailable)"
            ))
        }
        return choices
    }

    var builtInEditorThemeChoices: [EditorThemeChoice] {
        editorThemePickerChoices.filter { MarkdownEditorTheme(rawValue: $0.id) != nil }
    }

    var importedEditorThemeChoices: [EditorThemeChoice] {
        editorThemePickerChoices.filter { MarkdownEditorTheme(rawValue: $0.id) == nil }
    }

    func reloadImportedEditorThemes() {
        setImportedEditorThemes(editorThemeLibrary.loadCatalog().themes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        })
    }

    private func editorThemeNameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func editorThemeFallbackNotice(for identifier: String) -> String {
        """
        The editor theme \"\(identifier)\" could not be read. Plainsong is using the built-in \
        theme for this launch, and the saved selection was kept.
        """
    }

    private func themeData(at url: URL) throws -> Data {
        try editorThemeLibrary.readThemeFile(at: url)
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

/// Removes the Increase Contrast observer when preferences are released.
/// `isolated deinit` needs Swift 6.2; CI still compiles this target with Xcode 16.4.
final class EditorThemeContrastObservation: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let observer: NSObjectProtocol

    @MainActor
    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        Self.storeIncreaseContrast(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        notificationCenter = NSWorkspace.shared.notificationCenter
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                Self.storeIncreaseContrast(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
                onChange()
            }
        }
    }

    private static func storeIncreaseContrast(_ enabled: Bool) {
        MarkdownSyntaxTheme.noteAccessibilityIncreaseContrast(enabled)
    }

    deinit {
        notificationCenter.removeObserver(observer)
    }
}
