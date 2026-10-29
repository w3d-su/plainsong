import EditorKitIOS
import Foundation
import SwiftUI
import WorkspaceKitIOS

/// Settings that change a live iOS behavior. Experimental WYSIWYG stays off
/// this screen: the iOS editor does not implement it, and a toggle that does
/// nothing would be a false control.
@MainActor
final class IOSAppPreferences: ObservableObject {
    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    enum NewFileExtension: String, CaseIterable, Identifiable {
        case md
        case mdx

        var id: String {
            rawValue
        }

        var title: String {
            ".\(rawValue)"
        }
    }

    static let minimumAutosaveIntervalSeconds = 0.5
    static let maximumAutosaveIntervalSeconds = 30.0
    static let minimumEditorFontSize = 10.0
    static let maximumEditorFontSize = 24.0

    @Published private(set) var editorAppearance: Appearance
    @Published private(set) var editorFontName: String
    @Published private(set) var editorFontSize: Double
    @Published private(set) var editorPalette: IOSEditorTheme.Palette
    @Published private(set) var showsLineNumbers: Bool
    @Published private(set) var typewriterSyncEnabled: Bool
    @Published private(set) var autosaveIntervalSeconds: Double
    @Published private(set) var previewAppearance: Appearance
    @Published private(set) var allowsRemoteImages: Bool
    @Published private(set) var assetDirectoryName: String
    @Published private(set) var newFileExtension: NewFileExtension
    /// Bumped after every persisted change so SwiftUI can reapply live behavior.
    @Published private(set) var generation = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        editorAppearance = Appearance(rawValue: defaults.string(forKey: Key.editorAppearance) ?? "") ?? .system
        editorFontName = IOSEditorFont.resolved(defaults.string(forKey: Key.editorFontName) ?? IOSEditorFont.system)
        editorFontSize = Self.clampFont(defaults.object(forKey: Key.editorFontSize) as? Double ?? 13)
        editorPalette = IOSEditorTheme.Palette(rawValue: defaults.string(forKey: Key.editorPalette) ?? "") ?? .plainsong
        showsLineNumbers = defaults.object(forKey: Key.showsLineNumbers) as? Bool ?? true
        typewriterSyncEnabled = defaults.object(forKey: Key.typewriterSync) as? Bool ?? true
        autosaveIntervalSeconds = Self.clampAutosave(
            defaults.object(forKey: Key.autosave) as? Double ?? 1
        )
        previewAppearance = Appearance(rawValue: defaults.string(forKey: Key.previewAppearance) ?? "") ?? .system
        allowsRemoteImages = defaults.object(forKey: Key.remoteImages) as? Bool ?? false
        assetDirectoryName = IOSAssetDirectory.normalized(
            defaults.string(forKey: Key.assetDirectory) ?? "assets"
        )
        newFileExtension = NewFileExtension(rawValue: defaults.string(forKey: Key.newFileExtension) ?? "") ?? .md
    }

    func setEditorAppearance(_ appearance: Appearance) {
        guard editorAppearance != appearance else { return }
        editorAppearance = appearance
        defaults.set(appearance.rawValue, forKey: Key.editorAppearance)
        touch()
    }

    func setEditorFontName(_ name: String) {
        let resolved = IOSEditorFont.resolved(name)
        guard editorFontName != resolved else { return }
        editorFontName = resolved
        defaults.set(resolved, forKey: Key.editorFontName)
        touch()
    }

    func setEditorFontSize(_ size: Double) {
        let clamped = Self.clampFont(size)
        guard editorFontSize != clamped else { return }
        editorFontSize = clamped
        defaults.set(clamped, forKey: Key.editorFontSize)
        touch()
    }

    func setEditorPalette(_ palette: IOSEditorTheme.Palette) {
        guard editorPalette != palette else { return }
        editorPalette = palette
        defaults.set(palette.rawValue, forKey: Key.editorPalette)
        touch()
    }

    func setShowsLineNumbers(_ shown: Bool) {
        guard showsLineNumbers != shown else { return }
        showsLineNumbers = shown
        defaults.set(shown, forKey: Key.showsLineNumbers)
        touch()
    }

    func setTypewriterSyncEnabled(_ enabled: Bool) {
        guard typewriterSyncEnabled != enabled else { return }
        typewriterSyncEnabled = enabled
        defaults.set(enabled, forKey: Key.typewriterSync)
        touch()
    }

    func setAutosaveIntervalSeconds(_ seconds: Double) {
        let clamped = Self.clampAutosave(seconds)
        guard autosaveIntervalSeconds != clamped else { return }
        autosaveIntervalSeconds = clamped
        defaults.set(clamped, forKey: Key.autosave)
        touch()
    }

    func setPreviewAppearance(_ appearance: Appearance) {
        guard previewAppearance != appearance else { return }
        previewAppearance = appearance
        defaults.set(appearance.rawValue, forKey: Key.previewAppearance)
        touch()
    }

    func setAllowsRemoteImages(_ allowed: Bool) {
        guard allowsRemoteImages != allowed else { return }
        allowsRemoteImages = allowed
        defaults.set(allowed, forKey: Key.remoteImages)
        touch()
    }

    func setAssetDirectoryName(_ name: String) {
        let normalized = IOSAssetDirectory.normalized(name)
        guard assetDirectoryName != normalized else { return }
        assetDirectoryName = normalized
        defaults.set(normalized, forKey: Key.assetDirectory)
        touch()
    }

    func setNewFileExtension(_ fileExtension: NewFileExtension) {
        guard newFileExtension != fileExtension else { return }
        newFileExtension = fileExtension
        defaults.set(fileExtension.rawValue, forKey: Key.newFileExtension)
        touch()
    }

    var autosaveDelayNanoseconds: UInt64 {
        UInt64((autosaveIntervalSeconds * 1_000_000_000).rounded())
    }

    private func touch() {
        generation += 1
    }

    private static func clampFont(_ size: Double) -> Double {
        min(max(size, minimumEditorFontSize), maximumEditorFontSize)
    }

    private static func clampAutosave(_ seconds: Double) -> Double {
        min(max(seconds, minimumAutosaveIntervalSeconds), maximumAutosaveIntervalSeconds)
    }

    private enum Key {
        static let editorAppearance = "Plainsong.ios.settings.editorAppearance"
        static let editorFontName = "Plainsong.ios.settings.editorFontName"
        static let editorFontSize = "Plainsong.ios.settings.editorFontSize"
        static let editorPalette = "Plainsong.ios.settings.editorPalette"
        static let showsLineNumbers = "Plainsong.ios.settings.showsLineNumbers"
        static let typewriterSync = "Plainsong.ios.settings.typewriterSync"
        static let autosave = "Plainsong.ios.settings.autosaveIntervalSeconds"
        static let previewAppearance = "Plainsong.ios.settings.previewAppearance"
        static let remoteImages = "Plainsong.ios.settings.allowsRemoteImages"
        static let assetDirectory = "Plainsong.ios.settings.assetDirectory"
        static let newFileExtension = "Plainsong.ios.settings.newFileExtension"
    }
}

private struct IOSPreferencesKey: EnvironmentKey {
    static let defaultValue: IOSAppPreferences? = nil
}

extension EnvironmentValues {
    var plainsongPreferences: IOSAppPreferences? {
        get { self[IOSPreferencesKey.self] }
        set { self[IOSPreferencesKey.self] = newValue }
    }
}
