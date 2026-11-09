import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// Windows PR D1a (`docs/window-state-gates.md` W11 bullet 3): installed documents,
/// including every connected window's shown session, do not consume the 8 warm slots.
@MainActor
final class WindowSessionLRUInstalledAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var directory: URL!

    override func setUp() async throws {
        suiteName = "WindowSessionLRUInstalled-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowSessionLRUInstalled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        KeyWindowRouter.shared.resetForTesting()
        WindowOpenAdmission.resetForTesting()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func testTwoFacadesShowingDocumentsKeepEightWarmSessions() throws {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        let warmURLs = try writeFiles(named: (0 ..< 8).map { "warm-\($0).md" })
        let shownAURL = try write("shown-a.md", "shown a\n")
        let shownBURL = try write("shown-b.md", "shown b\n")
        let extraURL = try write("extra.md", "extra\n")

        var warmSessions: [DocumentSession] = []
        for url in warmURLs {
            try primary.activateFileSession(url: url)
            warmSessions.append(primary.shownSession)
        }
        try primary.activateFileSession(url: shownAURL)
        let shownA = primary.shownSession
        try second.activateFileSession(url: shownBURL)
        let shownB = second.shownSession

        let shownAStateURL = try XCTUnwrap(primary.sessionStateURL(for: shownA))
        let shownBStateURL = try XCTUnwrap(second.sessionStateURL(for: shownB))
        XCTAssertEqual(primary.installedSessionURLs(), [shownAStateURL, shownBStateURL])
        XCTAssertFalse(primary.protectedSessionURLs().contains(shownAStateURL))
        XCTAssertFalse(primary.protectedSessionURLs().contains(shownBStateURL))
        XCTAssertEqual(primary.registry.sessionCache.count, 10)
        for session in warmSessions {
            let url = try XCTUnwrap(primary.sessionStateURL(for: session))
            XCTAssertTrue(primary.registry.warmSession(at: url) === session)
            XCTAssertFalse(primary.installedSessionURLs().contains(url))
        }

        try primary.activateFileSession(url: extraURL)

        let evictedURL = try XCTUnwrap(primary.sessionStateURL(for: warmSessions[0]))
        XCTAssertNil(primary.registry.warmSession(at: evictedURL))
        for session in warmSessions.dropFirst() {
            let url = try XCTUnwrap(primary.sessionStateURL(for: session))
            XCTAssertTrue(primary.registry.warmSession(at: url) === session)
        }
        XCTAssertTrue(primary.registry.warmSession(at: shownAStateURL) === shownA)
        XCTAssertTrue(second.registry.warmSession(at: shownBStateURL) === shownB)
        XCTAssertEqual(primary.shownSession.fileURL?.lastPathComponent, "extra.md")
        XCTAssertEqual(second.shownSession.fileURL?.lastPathComponent, "shown-b.md")
        XCTAssertTrue(primary.installedSessionURLs().contains(shownBStateURL))
        XCTAssertFalse(primary.installedSessionURLs().contains(shownAStateURL))
    }

    func testEditorBindingInstallationDoesNotCountTowardWarmCapacity() throws {
        let primary = makePrimary()
        let installedURL = try write("installed.md", "installed\n")
        let installed = DocumentSession(
            text: "installed\n",
            url: installedURL,
            fileKind: .markdown
        )
        let installation = EditorDocumentBindingInstallation(
            bindingID: EditorDocumentBindingID(),
            installationID: EditorDocumentBindingInstallationID()
        )
        primary.registry.setWarmSession(installed, at: installedURL)
        primary.editorBindingInstallations[installation] = installed
        primary.handleSessionAccess(url: installedURL, isDirty: false)

        var warmSessions: [DocumentSession] = []
        for url in try writeFiles(named: (0 ..< 9).map { "warm-\($0).md" }) {
            try primary.activateFileSession(url: url)
            warmSessions.append(primary.shownSession)
        }
        XCTAssertEqual(primary.registry.sessionCache.count, 10)
        XCTAssertTrue(primary.registry.warmSession(at: installedURL) === installed)
        XCTAssertTrue(primary.installedSessionURLs().contains(installedURL))
        XCTAssertFalse(primary.protectedSessionURLs().contains(installedURL))

        let extraURL = try write("extra.md", "extra\n")
        try primary.activateFileSession(url: extraURL)

        XCTAssertTrue(primary.registry.warmSession(at: installedURL) === installed)
        XCTAssertNil(try primary.registry.warmSession(at: XCTUnwrap(primary.sessionStateURL(for: warmSessions[0]))))
        for session in warmSessions.dropFirst() {
            let url = try XCTUnwrap(primary.sessionStateURL(for: session))
            XCTAssertTrue(primary.registry.warmSession(at: url) === session)
        }
        XCTAssertEqual(primary.shownSession.fileURL?.lastPathComponent, "extra.md")
    }

    func testRevokingTheOldestEditorInstallationEvictsThatSession() throws {
        let primary = makePrimary()
        primary.sessionPolicy = .init(limit: 1)
        let oldestURL = try write("oldest.md", "oldest\n")
        let countableURL = try write("countable.md", "countable\n")
        let shownURL = try write("shown.md", "shown\n")

        try primary.activateFileSession(url: oldestURL)
        let oldest = primary.shownSession
        let binding = primary.editorDocumentBinding(for: oldest)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        try primary.activateFileSession(url: countableURL)
        let countable = primary.shownSession
        try primary.activateFileSession(url: shownURL)

        let oldestStateURL = try XCTUnwrap(primary.sessionStateURL(for: oldest))
        let countableStateURL = try XCTUnwrap(primary.sessionStateURL(for: countable))
        XCTAssertTrue(primary.installedSessionURLs().contains(oldestStateURL))
        XCTAssertFalse(primary.installedSessionURLs().contains(countableStateURL))
        XCTAssertTrue(primary.registry.warmSession(at: oldestStateURL) === oldest)

        binding.onLifecycle(.revoked(installation))

        XCTAssertNil(primary.registry.warmSession(at: oldestStateURL))
        XCTAssertFalse(primary.sessionPolicy.warmURLsInLeastRecentOrder.contains(oldestStateURL))
        XCTAssertTrue(primary.registry.warmSession(at: countableStateURL) === countable)
        XCTAssertEqual(primary.shownSession.fileURL?.lastPathComponent, "shown.md")
        XCTAssertFalse(primary.installedSessionURLs().contains(oldestStateURL))
    }

    func testRevokingANewerEditorInstallationEvictsTheOldestCountableSession() throws {
        let primary = makePrimary()
        primary.sessionPolicy = .init(limit: 1)
        let countableURL = try write("countable.md", "countable\n")
        let installedURL = try write("installed.md", "installed\n")
        let shownURL = try write("shown.md", "shown\n")

        try primary.activateFileSession(url: countableURL)
        let countable = primary.shownSession
        try primary.activateFileSession(url: installedURL)
        let installed = primary.shownSession
        let binding = primary.editorDocumentBinding(for: installed)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        try primary.activateFileSession(url: shownURL)

        let countableStateURL = try XCTUnwrap(primary.sessionStateURL(for: countable))
        let installedStateURL = try XCTUnwrap(primary.sessionStateURL(for: installed))
        let shownStateURL = try XCTUnwrap(primary.sessionStateURL(for: primary.shownSession))
        XCTAssertEqual(
            primary.sessionPolicy.warmURLsInLeastRecentOrder,
            [countableStateURL, installedStateURL, shownStateURL]
        )

        binding.onLifecycle(.revoked(installation))

        XCTAssertNil(primary.registry.warmSession(at: countableStateURL))
        XCTAssertTrue(primary.registry.warmSession(at: installedStateURL) === installed)
        XCTAssertTrue(primary.sessionPolicy.warmURLsInLeastRecentOrder.contains(installedStateURL))
        XCTAssertFalse(primary.installedSessionURLs().contains(installedStateURL))
        XCTAssertEqual(primary.shownSession.fileURL?.lastPathComponent, "shown.md")
    }

    private func makePrimary() -> AppState {
        AppState(shouldRestoreLastOpenedFile: false, userDefaults: defaults)
    }

    private func writeFiles(named names: [String]) throws -> [URL] {
        try names.map { try write($0, "\($0)\n") }
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
