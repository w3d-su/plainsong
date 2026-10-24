import Foundation
@testable import Plainsong
import XCTest

/// WYSIWYG left Experimental (docs/wysiwyg-release-checklist.md D.4): it is a normal layout
/// choice by default, the first-launch layout is unchanged, and the Settings switch stays
/// as the kill switch, keeping an opt-out recorded before the promotion.
@MainActor
final class WYSIWYGPromotionAppStateTests: XCTestCase {
    func testWYSIWYGIsALayoutChoiceByDefaultWithoutChangingTheFirstLaunchLayout() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appState = AppState(userDefaults: defaults)

        XCTAssertTrue(appState.preferences.experimentalWYSIWYGEnabled)
        XCTAssertTrue(appState.isExperimentalWYSIWYGAvailable)
        XCTAssertEqual(appState.layoutMode, .sourceOnly)
        XCTAssertFalse(appState.shouldUseWYSIWYGPresentation)
        XCTAssertNil(appState.wysiwygFallbackMessage)
        XCTAssertEqual(appState.layoutModeCommandTitle, "Show WYSIWYG")
        XCTAssertEqual(appState.layoutModeToolbarTitle, "WYSIWYG")
        XCTAssertFalse(appState.layoutModeToolbarHelp.contains("Experimental"))

        appState.cycleLayoutMode()
        XCTAssertEqual(appState.layoutMode, .wysiwyg)
        XCTAssertTrue(appState.shouldUseWYSIWYGPresentation)

        let relaunched = AppState(userDefaults: defaults)
        XCTAssertEqual(relaunched.layoutMode, .wysiwyg)
        XCTAssertNil(relaunched.wysiwygFallbackMessage)
    }

    func testOptOutStoredBeforeThePromotionStillTurnsWYSIWYGOff() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // The Experimental-era key and value, written by an older build.
        defaults.set(false, forKey: "Plainsong.settings.experimentalWYSIWYGEnabled")
        defaults.set(EditorLayoutMode.wysiwyg.rawValue, forKey: AppState.layoutModeDefaultsKey)

        let appState = AppState(userDefaults: defaults)

        XCTAssertFalse(appState.preferences.experimentalWYSIWYGEnabled)
        XCTAssertFalse(appState.isExperimentalWYSIWYGAvailable)
        XCTAssertEqual(appState.layoutMode, .sourceOnly)
        XCTAssertTrue(appState.wysiwygFallbackMessage?.contains("WYSIWYG is turned off in Settings") == true)
        appState.cycleLayoutMode()
        XCTAssertEqual(appState.layoutMode, .sourcePreview)
        appState.cycleLayoutMode()
        XCTAssertEqual(appState.layoutMode, .sourceOnly)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "PlainsongWYSIWYGPromotionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
