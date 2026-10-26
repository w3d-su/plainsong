import Combine
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Windows PR B1 / gate W1: the partition adds no publish, keeps each publish before its
/// change, releases with `AppState`, and loads each recovery store once.
@MainActor
final class WindowStatePartitionPublishAppTests: XCTestCase {
    // MARK: - Publishing

    /// A moved window `@Published` property publishes `AppState.objectWillChange` once,
    /// before the new value is visible, as the `AppState` stored property did.
    func testWindowPublishedPropertyPublishesOnceBeforeTheChange() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        var valuesSeenAtPublish: [Bool] = []
        let probe = appState.objectWillChange.sink { _ in
            valuesSeenAtPublish.append(appState.showAllFiles)
        }
        defer { probe.cancel() }

        appState.showAllFiles = true

        XCTAssertEqual(valuesSeenAtPublish, [false])
        XCTAssertTrue(appState.showAllFiles)
    }

    func testRegistryPublishedPropertyPublishesOnceBeforeTheChange() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        let notice = FileWriteArtifactNotice(
            destinationURL: URL(fileURLWithPath: "/tmp/WindowStatePartitionPublishAppTests.md"),
            destinationWasCommitted: true,
            artifactState: .none
        )
        var countsSeenAtPublish: [Int] = []
        let probe = appState.objectWillChange.sink { _ in
            countsSeenAtPublish.append(appState.fileWriteArtifactNotices.count)
        }
        defer { probe.cancel() }

        appState.fileWriteArtifactNotices.append(notice)

        XCTAssertEqual(countsSeenAtPublish, [0])
        XCTAssertEqual(appState.fileWriteArtifactNotices, [notice])
    }

    /// Unpublished stored properties stay unpublished in every container.
    func testUnpublishedMovedPropertiesDoNotPublish() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        var publishCount = 0
        let probe = appState.objectWillChange.sink { _ in publishCount += 1 }
        defer { probe.cancel() }

        appState.workspaceSearchQueryGeneration += 1
        appState.workspaceMutationRefreshPending = true
        appState.nextExternalReloadGeneration += 1
        appState.isSaving = true
        appState.sessionPolicy.updateDirtyState(
            for: URL(fileURLWithPath: "/tmp/WindowStatePartitionPublishAppTests.md"),
            isDirty: true
        )

        XCTAssertEqual(publishCount, 0)
    }

    /// No new keystroke publish: body edits publish `AppState` only by forwarding the
    /// session's own publishes (`observeCurrentDocument`), never a container's.
    func testBodyEditsPublishOnlyTheSessionsOwnChanges() {
        let session = DocumentSession(text: "alpha", fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        var appPublishCount = 0
        var sessionPublishCount = 0
        let appProbe = appState.objectWillChange.sink { _ in appPublishCount += 1 }
        let sessionProbe = session.objectWillChange.sink { _ in sessionPublishCount += 1 }
        defer {
            appProbe.cancel()
            sessionProbe.cancel()
        }

        var text = session.text
        for _ in 0 ..< 20 {
            text += "b"
            appState.replaceDocumentText(text)
        }

        XCTAssertEqual(session.text, text)
        XCTAssertEqual(appPublishCount, sessionPublishCount)
        XCTAssertLessThanOrEqual(sessionPublishCount, 1, "Only the first edit can change isDirty")
    }

    // MARK: - Lifetime

    /// The containers have no reference cycle with `AppState`, so releasing it releases them
    /// and their `deinit` cancels the work `AppState.deinit` used to cancel.
    func testReleasingAppStateReleasesItsContainersAndCancelsTheirWork() {
        weak var releasedAppState: AppState?
        weak var releasedWindowState: WindowState?
        weak var releasedRootContext: WorkspaceRootContext?
        weak var releasedRegistry: AppDocumentRegistry?
        var tasks: [Task<Void, Never>] = []
        autoreleasepool {
            let appState = AppState(shouldRestoreLastOpenedFile: false)
            let window = Self.sleepingTask()
            let completion = Self.sleepingTask()
            let reload = Self.sleepingTask()
            let recovery = Self.sleepingTask()
            appState.workspaceSearchTask = window
            appState.completionWorkspaceTask = completion
            appState.workspaceReloadTask = reload
            appState.workspaceMutationTextRecoveryTasks[ObjectIdentifier(appState)] = recovery
            tasks = [window, completion, reload, recovery]
            releasedAppState = appState
            releasedWindowState = appState.windowState
            releasedRootContext = appState.workspaceRootContext
            releasedRegistry = appState.registry
        }

        XCTAssertNil(releasedAppState)
        XCTAssertNil(releasedWindowState)
        XCTAssertNil(releasedRootContext)
        XCTAssertNil(releasedRegistry)
        XCTAssertEqual(tasks.map(\.isCancelled), [true, true, true, true])
    }

    // MARK: - Recovery stores

    /// Each recovery store still loads exactly once per `AppState`, now in the registry.
    func testRecoveryStoresLoadExactlyOncePerAppState() {
        let operationStore = CountingOperationRecoveryStore()
        let textStore = CountingTextRecoveryStore()

        _ = AppState(
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: textStore,
            shouldRestoreLastOpenedFile: false
        )

        XCTAssertEqual(operationStore.loadCount, 1)
        XCTAssertEqual(textStore.loadCount, 1)
    }

    /// A load failure recorded by the registry still fences file access through the façade.
    func testRecoveryLoadFailureInTheRegistryStillFencesSaving() throws {
        let operationStore = CountingOperationRecoveryStore()
        operationStore.loadError = CocoaError(.fileReadCorruptFile)
        let session = DocumentSession(
            text: "body",
            url: URL(fileURLWithPath: "/tmp/WindowStatePartitionPublishAppTests/post.md"),
            fileKind: .markdown
        )
        let appState = AppState(
            currentDocument: session,
            workspaceMutationOperationRecoveryStore: operationStore,
            workspaceMutationTextRecoveryStore: CountingTextRecoveryStore(),
            shouldRestoreLastOpenedFile: false
        )

        XCTAssertTrue(appState.registry.workspaceMutationOperationRecoveryLoadFailed)
        XCTAssertTrue(appState.hasWorkspaceMutationRecoveryLoadFailure)
        XCTAssertFalse(appState.canSave)
        XCTAssertThrowsError(try appState.validateWorkspaceMutationRecoveryStoresLoaded())
    }

    private static func sleepingTask() -> Task<Void, Never> {
        Task { try? await Task.sleep(nanoseconds: 60_000_000_000) }
    }
}

private final class CountingOperationRecoveryStore: WorkspaceMutationOperationRecoveryPersisting {
    private(set) var loadCount = 0
    var loadError: Error?

    func load() throws -> [WorkspaceMutationOperationRecoveryRecord] {
        loadCount += 1
        if let loadError { throw loadError }
        return []
    }

    func upsert(_: WorkspaceMutationOperationRecoveryRecord) {}

    func remove(id _: UUID) {}
}

private final class CountingTextRecoveryStore: WorkspaceMutationTextRecoveryPersisting {
    private(set) var loadCount = 0

    func load() -> [WorkspaceMutationTextRecoveryRecord] {
        loadCount += 1
        return []
    }

    func upsert(_: WorkspaceMutationTextRecoveryRecord) {}

    func remove(id _: UUID) {}

    func quarantine(id _: UUID) {}
}
