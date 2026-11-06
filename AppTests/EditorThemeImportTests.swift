import AppKit
import Darwin
import EditorKit
import MarkdownCore
@testable import Plainsong
import XCTest

@MainActor
final class EditorThemeImportTests: XCTestCase {
    func testImportCopiesIntoTheThemeDirectoryAndReplacePromptGatesOverwrite() throws {
        let fixture = try Fixture()
        let original = Data("""
        {"schemaVersion":1,"id":"solarized-ink","name":"Solarized Ink","light":{"editor":{"text":"#112233"}}}
        """.utf8)

        let source = fixture.write("solar.json", original)
        var prompts = 0
        fixture.preferences.confirmEditorThemeReplacement = { identifier, name in
            prompts += 1
            XCTAssertEqual(identifier, "solarized-ink")
            XCTAssertEqual(name, "Solarized Ink")
            return false
        }

        let imported = try fixture.preferences.importEditorTheme(from: source)
        guard case let .imported(document) = imported else {
            return XCTFail("expected import")
        }
        XCTAssertEqual(document.id, "solarized-ink")
        XCTAssertEqual(prompts, 0)
        let stored = fixture.directory.appendingPathComponent("solarized-ink.json")
        XCTAssertEqual(try Data(contentsOf: stored), original)
        XCTAssertEqual(fixture.preferences.editorThemeIdentifier, "solarized-ink")
        XCTAssertNil(fixture.preferences.userDefaults.data(forKey: "Plainsong.settings.editorThemeBookmark"))
        XCTAssertFalse(fixture.preferences.userDefaults.dictionaryRepresentation().keys.contains {
            $0.localizedCaseInsensitiveContains("bookmark") && $0.localizedCaseInsensitiveContains("theme")
        })

        let replacement = Data("""
        {"schemaVersion":1,"id":"solarized-ink","name":"Solarized Ink","light":{"editor":{"text":"#AABBCC"}}}
        """.utf8)

        let replacementURL = fixture.write("replacement.json", replacement)
        let declined = try fixture.preferences.importEditorTheme(from: replacementURL)
        XCTAssertEqual(declined, .replacementDeclined(id: "solarized-ink"))
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(try Data(contentsOf: stored), original)

        fixture.preferences.confirmEditorThemeReplacement = { _, _ in true }
        let replaced = try fixture.preferences.importEditorTheme(from: replacementURL)
        guard case .imported = replaced else {
            return XCTFail("expected replacement")
        }
        XCTAssertEqual(try Data(contentsOf: stored), replacement)
        var red: CGFloat = -1
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            red = fixture.preferences.resolvedEditorSyntaxTheme.textColor.cgColor.components?.first ?? -1
        }
        XCTAssertEqual(red, 0xAA / 255, accuracy: 0.02)
    }

    func testRevealTargetsTheContainerCopyAndRemoveMovesItToTheTrash() throws {
        let fixture = try Fixture()
        let source = fixture.write(
            "ink.json",
            Data("""
            {"schemaVersion":1,"id":"ink","name":"Ink","light":{}}
            """.utf8)
        )
        _ = try fixture.preferences.importEditorTheme(from: source)
        var revealed: URL?
        fixture.preferences.revealEditorThemeFile = { revealed = $0 }
        fixture.preferences.revealSelectedEditorTheme()
        XCTAssertEqual(revealed, fixture.directory.appendingPathComponent("ink.json"))

        let trashed = try fixture.preferences.removeSelectedEditorTheme()
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: fixture.directory.appendingPathComponent("ink.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertEqual(fixture.preferences.editorThemeIdentifier, "standard")
        XCTAssertEqual(fixture.preferences.editorTheme, .standard)
    }

    func testInvalidStoredThemeFallsBackWithoutAModalAndKeepsTheIdentifier() throws {
        let fixture = try Fixture()
        let identifier = "broken-ink"
        try Data("{".utf8).write(to: fixture.directory.appendingPathComponent("\(identifier).json"))
        fixture.preferences.userDefaults.set(identifier, forKey: PlainsongPreferences.Keys.editorTheme)
        let reloaded = PlainsongPreferences(
            userDefaults: fixture.preferences.userDefaults,
            editorThemeLibrary: fixture.library
        )

        XCTAssertEqual(reloaded.editorThemeIdentifier, identifier)
        XCTAssertEqual(reloaded.editorTheme, .standard)
        XCTAssertEqual(reloaded.resolvedEditorSyntaxTheme.textColor, MarkdownSyntaxTheme.standard.textColor)
        XCTAssertEqual(
            reloaded.editorThemeFallbackNotice,
            PlainsongPreferences.editorThemeFallbackNotice(for: identifier)
        )
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertEqual(reloaded.userDefaults.string(forKey: PlainsongPreferences.Keys.editorTheme), identifier)

        reloaded.dismissEditorThemeFallbackNotice()
        XCTAssertNil(reloaded.editorThemeFallbackNotice)
        XCTAssertEqual(reloaded.userDefaults.string(forKey: PlainsongPreferences.Keys.editorTheme), identifier)
    }

    func testReplacePromptOffersReplaceAndCancel() {
        let alert = CustomThemeReplacePrompt.alert(identifier: "ink", name: "Ink")
        XCTAssertEqual(alert.messageText, "Replace theme \"Ink\"?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Replace", "Cancel"])
    }

    func testFailureAlertKeepsTheValidationReason() {
        let imported = EditorThemeFailureAlert.make(
            messageText: "Could not import theme",
            error: EditorThemeStoreError.invalid(.unknownField("css"))
        )
        XCTAssertEqual(imported.messageText, "Could not import theme")
        XCTAssertTrue(imported.informativeText.contains("unknown field"))
        XCTAssertTrue(imported.informativeText.contains("css"))

        let removed = EditorThemeFailureAlert.make(
            messageText: "Could not remove theme",
            error: EditorThemeStoreError.notFound("missing")
        )
        XCTAssertEqual(removed.messageText, "Could not remove theme")
        XCTAssertTrue(removed.informativeText.contains("missing"))
        XCTAssertNotEqual(removed.messageText, removed.informativeText)
    }

    func testRejectedImportWritesNothingAndKeepsTheSelection() throws {
        let fixture = try Fixture()
        let before = fixture.preferences.editorThemeIdentifier
        let oversized = Data(repeating: 0x20, count: CustomThemeDocument.maximumByteCount + 1)
        XCTAssertThrowsError(try fixture.preferences.importEditorTheme(from: fixture.write(
            "big.json",
            oversized
        ))) { error in
            guard case EditorThemeStoreError.invalid(.exceedsMaximumSize) = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertThrowsError(try fixture.preferences.importEditorTheme(from: fixture.directory))
        let invalid = fixture.write(
            "nope.json",
            Data("{\"schemaVersion\":1,\"id\":\"nope\",\"name\":\"Nope\",\"light\":{},\"css\":\"x\"}".utf8)
        )
        XCTAssertThrowsError(try fixture.preferences.importEditorTheme(from: invalid))
        XCTAssertEqual(fixture.preferences.editorThemeIdentifier, before)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil).count,
            0
        )
    }

    func testLoadCatalogSkipsSymlinksMismatchedNamesAndOversizedFiles() throws {
        let fixture = try Fixture()
        let valid = Data("{\"schemaVersion\":1,\"id\":\"ink\",\"name\":\"Ink\",\"light\":{}}".utf8)
        try valid.write(to: fixture.directory.appendingPathComponent("ink.json"))
        try Data("{\"schemaVersion\":1,\"id\":\"other\",\"name\":\"Other\",\"light\":{}}".utf8)
            .write(to: fixture.directory.appendingPathComponent("mismatched.json"))
        try Data(repeating: 0x7B, count: CustomThemeDocument.maximumByteCount + 8)
            .write(to: fixture.directory.appendingPathComponent("huge.json"))
        let outside = fixture.write("linked.json", valid)
        try FileManager.default.createSymbolicLink(
            at: fixture.directory.appendingPathComponent("linked.json"),
            withDestinationURL: outside
        )
        try FileManager.default.createDirectory(
            at: fixture.directory.appendingPathComponent("folder.json"),
            withIntermediateDirectories: true
        )

        let catalog = fixture.library.loadCatalog()
        XCTAssertEqual(catalog.themes.map(\.id), ["ink"])
        XCTAssertEqual(catalog.invalidIdentifiers, Set(["mismatched", "huge", "linked", "folder"]))
    }

    func testLoadCatalogDoesNotBlockOnAFifo() throws {
        let fixture = try Fixture()
        let fifo = fixture.directory.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        let catalog = fixture.library.loadCatalog()
        XCTAssertEqual(catalog.themes, [])
        XCTAssertTrue(catalog.invalidIdentifiers.contains("pipe"))
    }

    func testContrastObservationReceivesWorkspaceNotifications() async {
        let received = expectation(description: "Accessibility display options changed")
        let observation = EditorThemeContrastObservation {
            received.fulfill()
        }
        defer { withExtendedLifetime(observation) {} }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        await fulfillment(of: [received], timeout: 2)
    }

    func testPickerShowsTheIdWhenANameCollides() throws {
        let fixture = try Fixture()
        for (id, name) in [("plainsong-copy", "Plainsong"), ("ink-a", "Ink"), ("ink-b", "ink"), ("solo", "Solo")] {
            let payload = Data("""
            {"schemaVersion":1,"id":"\(id)","name":"\(name)","light":{}}
            """.utf8)
            _ = try fixture.preferences.importEditorTheme(from: fixture.write("\(id).json", payload))
        }
        let names = fixture.preferences.editorThemePickerChoices.map(\.name)
        XCTAssertTrue(names.contains("Plainsong"))
        XCTAssertTrue(names.contains("Plainsong (plainsong-copy)"))
        XCTAssertTrue(names.contains("Ink (ink-a)"))
        XCTAssertTrue(names.contains("ink (ink-b)"))
        XCTAssertTrue(names.contains("Solo"))
        XCTAssertFalse(names.contains("Solo (solo)"))
        let sections = fixture.preferences.editorThemePickerSections
        XCTAssertEqual(sections.builtIn.map(\.name), ["Plainsong", "Graphite"])
        XCTAssertFalse(sections.builtIn.contains { $0.id == "plainsong-copy" })
        XCTAssertTrue(sections.imported.contains { $0.id == "plainsong-copy" })
        XCTAssertEqual(sections.builtIn + sections.imported, fixture.preferences.editorThemePickerChoices)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let library: EditorThemeLibrary
        let preferences: PlainsongPreferences

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("plainsong-themes-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("Library/Application Support/Plainsong/Themes", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            library = EditorThemeLibrary(directory: directory)
            let suiteName = "PlainsongEditorThemes.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            preferences = PlainsongPreferences(userDefaults: defaults, editorThemeLibrary: library)
        }

        func write(_ name: String, _ data: Data) -> URL {
            let url = directory.deletingLastPathComponent().appendingPathComponent(name)
            try! data.write(to: url)
            return url
        }
    }
}
