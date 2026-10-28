import Combine
import Foundation
@testable import Plainsong
import XCTest

/// W5 bullet 4: Save enablement follows the key façade without menu churn.
@MainActor
final class WindowFacadeMenuEnablementAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var directory: URL!

    override func setUp() async throws {
        suiteName = "WindowFacadeMenu-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowFacadeMenu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        KeyWindowRouter.shared.testingPin = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func testBackgroundSaveAndRegistryFencesUpdateSaveWithoutMenuChurn() async throws {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        let file = try write("active.md", "hello\n")
        try second.open(url: file, rememberAsLastOpened: false, preserveWorkspace: true)
        try await waitUntilMenu("opened file can save") { second.canSave }
        KeyWindowRouter.shared.testingPin = second
        let menu = MenuBarState()
        XCTAssertTrue(menu.snapshot.canSave)
        var publishes = 0
        let subscription = menu.$snapshot.dropFirst().sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        let identity = ObjectIdentifier(second.shownSession)
        second.workspaceMutationWriteFences.insert(identity)
        try await settleMenu()
        XCTAssertFalse(menu.snapshot.canSave)
        let fenced = publishes
        XCTAssertGreaterThan(fenced, 0)

        primary.updateWorkspaceSearchQueryText("noise")
        try await settleMenu()
        XCTAssertEqual(publishes, fenced, "a background window must not rebuild the menu")

        second.workspaceMutationWriteFences.remove(identity)
        try await settleMenu()
        XCTAssertTrue(menu.snapshot.canSave)
        XCTAssertGreaterThan(publishes, fenced)

        second.indeterminateWorkspaceMutationSessions.insert(identity)
        try await settleMenu()
        XCTAssertFalse(menu.snapshot.canSave)
        second.indeterminateWorkspaceMutationSessions.remove(identity)
        try await settleMenu()
        XCTAssertTrue(menu.snapshot.canSave)

        second.workspaceMutationOperationRecoveryLoadFailed = true
        try await settleMenu()
        XCTAssertFalse(menu.snapshot.canSave)
        second.workspaceMutationOperationRecoveryLoadFailed = false
        try await settleMenu()
        XCTAssertTrue(menu.snapshot.canSave)

        second.recentItemURLs = [file]
        try await settleMenu()
        XCTAssertEqual(menu.snapshot.recentItemURLs, [file])
        let afterRecents = publishes
        primary.updateWorkspaceSearchQueryText("more-noise")
        try await settleMenu()
        XCTAssertEqual(publishes, afterRecents)

        second.isSaving = true
        second.registry.noteMenuEnablementDidChange()
        try await settleMenu()
        XCTAssertFalse(menu.snapshot.canSave)
        second.isSaving = false
        second.registry.noteMenuEnablementDidChange()
        try await settleMenu()
        XCTAssertTrue(menu.snapshot.canSave)

        second.replaceDocumentText("hello!\n")
        try primary.save(session: second.shownSession)
        try await settleMenu()
        XCTAssertFalse(second.shownSession.isDirty)
        XCTAssertTrue(menu.snapshot.canSave)
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            "hello!\n"
        )
    }

    private func settleMenu() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    private func waitUntilMenu(
        _ description: String,
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func makePrimary() -> AppState {
        AppState(shouldRestoreLastOpenedFile: false, userDefaults: defaults)
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
