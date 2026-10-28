import EditorKitIOS
import Foundation
@testable import PlainsongIOS
import XCTest

@MainActor
final class IOSAppPreferencesTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "app.plainsong.ios.settings.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testInvalidValuesClampAndTraversalCannotLeaveTheAssetFolder() {
        defaults.set("sideways", forKey: "Plainsong.ios.settings.editorAppearance")
        defaults.set(80.0, forKey: "Plainsong.ios.settings.editorFontSize")
        defaults.set(0.1, forKey: "Plainsong.ios.settings.autosaveIntervalSeconds")
        defaults.set("../secret", forKey: "Plainsong.ios.settings.assetDirectory")
        defaults.set("mdx", forKey: "Plainsong.ios.settings.newFileExtension")
        let preferences = IOSAppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.editorAppearance, .system)
        XCTAssertEqual(preferences.editorFontSize, 24)
        XCTAssertEqual(preferences.autosaveIntervalSeconds, 0.5)
        XCTAssertEqual(preferences.assetDirectoryName, "assets")
        XCTAssertEqual(preferences.newFileExtension, .mdx)

        preferences.setEditorFontSize(9)
        preferences.setAutosaveIntervalSeconds(45)
        preferences.setAssetDirectoryName("media")
        XCTAssertEqual(preferences.assetDirectoryName, "media")
        preferences.setAssetDirectoryName("a/b")
        XCTAssertEqual(preferences.assetDirectoryName, "assets")
        let reloaded = IOSAppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.editorFontSize, 10)
        XCTAssertEqual(reloaded.autosaveIntervalSeconds, 30)
        XCTAssertEqual(reloaded.assetDirectoryName, "assets")
        XCTAssertEqual(reloaded.newFileExtension, .mdx)
        XCTAssertEqual(preferences.generation, 4)
    }

    func testEditorChromePreferencesRoundTrip() {
        defaults.set("Comic Sans", forKey: "Plainsong.ios.settings.editorFontName")
        defaults.set("graphite", forKey: "Plainsong.ios.settings.editorPalette")
        defaults.set(false, forKey: "Plainsong.ios.settings.showsLineNumbers")
        defaults.set(false, forKey: "Plainsong.ios.settings.typewriterSync")
        let preferences = IOSAppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.editorFontName, IOSEditorFont.system)
        XCTAssertEqual(preferences.editorPalette, .graphite)
        XCTAssertFalse(preferences.showsLineNumbers)
        XCTAssertFalse(preferences.typewriterSyncEnabled)

        let font = IOSEditorFont.availableTitles().contains("Menlo") ? "Menlo" : IOSEditorFont.system
        preferences.setEditorFontName(font)
        preferences.setEditorPalette(.plainsong)
        preferences.setShowsLineNumbers(true)
        preferences.setTypewriterSyncEnabled(true)
        let reloaded = IOSAppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.editorFontName, font)
        XCTAssertEqual(reloaded.editorPalette, .plainsong)
        XCTAssertTrue(reloaded.showsLineNumbers)
        XCTAssertTrue(reloaded.typewriterSyncEnabled)
        XCTAssertEqual(preferences.generation, 4)
    }
}
