import AppKit
import Combine
import EditorKit
import Foundation
import WorkspaceKit

@MainActor
final class PlainsongPreferences: ObservableObject {
    enum PreviewTheme: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .system:
                "System"
            case .light:
                "Light"
            case .dark:
                "Dark"
            }
        }
    }

    enum DefaultFileExtension: String, CaseIterable, Identifiable {
        case md
        case mdx

        var id: String {
            rawValue
        }

        var displayName: String {
            ".\(rawValue)"
        }
    }

    static let defaultAutosaveIntervalSeconds = 1.0
    static let defaultAssetFolderRelativePath = "assets"
    static let minimumAutosaveIntervalSeconds = 0.5
    static let maximumAutosaveIntervalSeconds = 30.0
    static let minimumEditorFontSize = 10.0
    static let maximumEditorFontSize = 24.0

    @Published private(set) var defaultFolderURL: URL?
    @Published private(set) var autosaveIntervalSeconds: Double
    @Published private(set) var editorFontName: String
    @Published private(set) var editorFontSize: Double
    @Published private(set) var showsLineNumbers: Bool
    @Published private(set) var typewriterSyncEnabled: Bool
    @Published private(set) var editorTheme: MarkdownEditorTheme
    @Published private(set) var previewTheme: PreviewTheme
    @Published private(set) var allowsRemoteImages: Bool
    @Published private(set) var experimentalWYSIWYGEnabled: Bool
    @Published private(set) var assetFolderRelativePath: String
    @Published private(set) var defaultFileExtension: DefaultFileExtension

    var onChange: (() -> Void)?

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        defaultFolderURL = Self.resolveDefaultFolderURL(from: userDefaults)
        autosaveIntervalSeconds = Self.clampedAutosaveInterval(
            userDefaults.object(forKey: Keys.autosaveIntervalSeconds) as? Double
                ?? Self.defaultAutosaveIntervalSeconds
        )
        editorFontName = userDefaults.string(forKey: Keys.editorFontName)
            ?? MarkdownSyntaxHighlighter.systemMonospacedFontName
        editorFontSize = Self.clampedEditorFontSize(
            userDefaults.object(forKey: Keys.editorFontSize) as? Double
                ?? Double(MarkdownSyntaxHighlighter.defaultFont.pointSize)
        )
        showsLineNumbers = userDefaults.object(forKey: Keys.showsLineNumbers) as? Bool ?? true
        typewriterSyncEnabled = userDefaults.object(forKey: Keys.typewriterSyncEnabled) as? Bool ?? true
        editorTheme = userDefaults.string(forKey: Keys.editorTheme)
            .flatMap(MarkdownEditorTheme.init(rawValue:)) ?? .standard
        previewTheme = userDefaults.string(forKey: Keys.previewTheme)
            .flatMap(PreviewTheme.init(rawValue:)) ?? .system
        allowsRemoteImages = userDefaults.object(forKey: Keys.allowsRemoteImages) as? Bool ?? false
        experimentalWYSIWYGEnabled = userDefaults.object(forKey: Keys.experimentalWYSIWYGEnabled) as? Bool ?? false
        assetFolderRelativePath = Self.normalizedAssetFolder(
            userDefaults.string(forKey: Keys.assetFolderRelativePath)
                ?? Self.defaultAssetFolderRelativePath
        )
        defaultFileExtension = userDefaults.string(forKey: Keys.defaultFileExtension)
            .flatMap(DefaultFileExtension.init(rawValue:)) ?? .md
    }

    var editorFont: NSFont {
        MarkdownSyntaxHighlighter.editorFont(named: editorFontName, size: CGFloat(editorFontSize))
    }

    var editorAppearanceID: String {
        "\(editorTheme.rawValue):\(editorFontName):\(editorFontSize)"
    }

    func setDefaultFolderURL(_ url: URL?) throws {
        guard let url else {
            userDefaults.removeObject(forKey: Keys.defaultFolderBookmarkData)
            defaultFolderURL = nil
            notifyDidChange()
            return
        }

        let standardizedURL = url.standardizedFileURL
        let bookmarkData = try SecurityScopedAccess.withAccess(to: standardizedURL) {
            try standardizedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        userDefaults.set(bookmarkData, forKey: Keys.defaultFolderBookmarkData)
        defaultFolderURL = standardizedURL
        notifyDidChange()
    }

    func setAutosaveIntervalSeconds(_ seconds: Double) {
        let clamped = Self.clampedAutosaveInterval(seconds)
        guard autosaveIntervalSeconds != clamped else { return }

        autosaveIntervalSeconds = clamped
        userDefaults.set(clamped, forKey: Keys.autosaveIntervalSeconds)
        notifyDidChange()
    }

    func setEditorFontName(_ fontName: String) {
        let normalized = fontName.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = normalized.isEmpty ? MarkdownSyntaxHighlighter.systemMonospacedFontName : normalized
        guard editorFontName != next else { return }

        editorFontName = next
        userDefaults.set(next, forKey: Keys.editorFontName)
        notifyDidChange()
    }

    func setEditorFontSize(_ fontSize: Double) {
        let clamped = Self.clampedEditorFontSize(fontSize)
        guard editorFontSize != clamped else { return }

        editorFontSize = clamped
        userDefaults.set(clamped, forKey: Keys.editorFontSize)
        notifyDidChange()
    }

    func setShowsLineNumbers(_ showsLineNumbers: Bool) {
        guard self.showsLineNumbers != showsLineNumbers else { return }

        self.showsLineNumbers = showsLineNumbers
        userDefaults.set(showsLineNumbers, forKey: Keys.showsLineNumbers)
        notifyDidChange()
    }

    func setTypewriterSyncEnabled(_ isEnabled: Bool) {
        guard typewriterSyncEnabled != isEnabled else { return }

        typewriterSyncEnabled = isEnabled
        userDefaults.set(isEnabled, forKey: Keys.typewriterSyncEnabled)
        notifyDidChange()
    }

    func setEditorTheme(_ theme: MarkdownEditorTheme) {
        guard editorTheme != theme else { return }

        editorTheme = theme
        userDefaults.set(theme.rawValue, forKey: Keys.editorTheme)
        notifyDidChange()
    }

    func setPreviewTheme(_ theme: PreviewTheme) {
        guard previewTheme != theme else { return }

        previewTheme = theme
        userDefaults.set(theme.rawValue, forKey: Keys.previewTheme)
        notifyDidChange()
    }

    func setAllowsRemoteImages(_ allowsRemoteImages: Bool) {
        guard self.allowsRemoteImages != allowsRemoteImages else { return }

        self.allowsRemoteImages = allowsRemoteImages
        userDefaults.set(allowsRemoteImages, forKey: Keys.allowsRemoteImages)
        notifyDidChange()
    }

    func setExperimentalWYSIWYGEnabled(_ isEnabled: Bool) {
        guard experimentalWYSIWYGEnabled != isEnabled else { return }

        experimentalWYSIWYGEnabled = isEnabled
        userDefaults.set(isEnabled, forKey: Keys.experimentalWYSIWYGEnabled)
        notifyDidChange()
    }

    func setAssetFolderRelativePath(_ path: String) {
        let normalized = Self.normalizedAssetFolder(path)
        guard assetFolderRelativePath != normalized else { return }

        assetFolderRelativePath = normalized
        userDefaults.set(normalized, forKey: Keys.assetFolderRelativePath)
        notifyDidChange()
    }

    func setDefaultFileExtension(_ fileExtension: DefaultFileExtension) {
        guard defaultFileExtension != fileExtension else { return }

        defaultFileExtension = fileExtension
        userDefaults.set(fileExtension.rawValue, forKey: Keys.defaultFileExtension)
        notifyDidChange()
    }

    private func notifyDidChange() {
        onChange?()
    }

    private static func clampedAutosaveInterval(_ seconds: Double) -> Double {
        min(max(seconds, minimumAutosaveIntervalSeconds), maximumAutosaveIntervalSeconds)
    }

    private static func clampedEditorFontSize(_ size: Double) -> Double {
        min(max(size, minimumEditorFontSize), maximumEditorFontSize)
    }

    private static func normalizedAssetFolder(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultAssetFolderRelativePath : trimmed
    }

    private static func resolveDefaultFolderURL(from userDefaults: UserDefaults) -> URL? {
        guard let bookmarkData = userDefaults.data(forKey: Keys.defaultFolderBookmarkData) else {
            return nil
        }

        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL
    }

    private enum Keys {
        static let defaultFolderBookmarkData = "Plainsong.settings.defaultFolderBookmark"
        static let autosaveIntervalSeconds = "Plainsong.settings.autosaveIntervalSeconds"
        static let editorFontName = "Plainsong.settings.editorFontName"
        static let editorFontSize = "Plainsong.settings.editorFontSize"
        static let showsLineNumbers = "Plainsong.settings.showsLineNumbers"
        static let typewriterSyncEnabled = "Plainsong.settings.typewriterSyncEnabled"
        static let editorTheme = "Plainsong.settings.editorTheme"
        static let previewTheme = "Plainsong.settings.previewTheme"
        static let allowsRemoteImages = "Plainsong.settings.allowsRemoteImages"
        static let experimentalWYSIWYGEnabled = "Plainsong.settings.experimentalWYSIWYGEnabled"
        static let assetFolderRelativePath = "Plainsong.settings.assetFolderRelativePath"
        static let defaultFileExtension = "Plainsong.settings.defaultFileExtension"
    }
}
