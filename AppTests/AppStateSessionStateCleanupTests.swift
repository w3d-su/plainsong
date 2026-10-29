import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

// swiftlint:disable function_body_length
@MainActor
final class AppStateSessionStateCleanupTests: XCTestCase {
    func testSwitchReleasesUnboundUntitledOwnershipBeforeIdentityCanBeReused() throws {
        let fixture = try SessionStateCleanupFixture()
        defer { fixture.cleanUp() }
        let appState = fixture.makeAppState(shownSession: DocumentSession())
        weak var initialSession: DocumentSession?
        initialSession = appState.shownSession
        let initialIdentity = ObjectIdentifier(appState.shownSession)
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[initialIdentity],
            .unavailable(fileURL: nil)
        )
        try "disk".write(to: fixture.url("post.md"), atomically: false, encoding: .utf8)

        try appState.activateFileSession(url: fixture.url("post.md"))

        XCTAssertNil(initialSession)
        XCTAssertNil(appState.unanchoredManagedSessionOwnershipProofs[initialIdentity])
        XCTAssertEqual(appState.sessionStateURL(for: appState.shownSession), fixture.url("post.md"))
    }

    func testSwitchRetainsBoundUntitledOwnershipUntilRegistrationIsRemoved() throws {
        let fixture = try SessionStateCleanupFixture()
        defer { fixture.cleanUp() }
        let initialSession = DocumentSession()
        let appState = fixture.makeAppState(shownSession: initialSession)
        let initialIdentity = ObjectIdentifier(initialSession)
        let binding = appState.editorDocumentBinding(for: initialSession)
        try "disk".write(to: fixture.url("post.md"), atomically: false, encoding: .utf8)

        try appState.activateFileSession(url: fixture.url("post.md"))

        XCTAssertEqual(appState.editorDocumentBindingIDs[initialIdentity], binding.id)
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[initialIdentity],
            .unavailable(fileURL: nil)
        )
        appState.removeEditorDocumentBindingRegistration(for: initialSession)
        XCTAssertNil(appState.unanchoredManagedSessionOwnershipProofs[initialIdentity])
    }

    func testStopTrackingReleasesUnreferencedRecoveryOwnershipBeforeIdentityCanBeReused() throws {
        let fixture = try SessionStateCleanupFixture()
        defer { fixture.cleanUp() }
        let appState = fixture.makeAppState(shownSession: DocumentSession())
        weak var recoverySession: DocumentSession?
        recoverySession = try stopTrackingRestoredRecovery(in: appState, fixture: fixture)
        let recoveryIdentity = try ObjectIdentifier(XCTUnwrap(recoverySession))
        try "disk".write(to: fixture.url("post.md"), atomically: false, encoding: .utf8)

        try appState.activateFileSession(url: fixture.url("post.md"))

        XCTAssertNil(recoverySession)
        XCTAssertNil(appState.unanchoredManagedSessionOwnershipProofs[recoveryIdentity])
        XCTAssertEqual(appState.sessionStateURL(for: appState.shownSession), fixture.url("post.md"))
    }

    func testStopTrackingRetainsBoundRecoveryOwnershipUntilRegistrationIsRemoved() throws {
        let fixture = try SessionStateCleanupFixture()
        defer { fixture.cleanUp() }
        let appState = fixture.makeAppState(shownSession: DocumentSession())
        let recoverySession = try stopTrackingRestoredRecovery(in: appState, fixture: fixture)
        let recoveryIdentity = ObjectIdentifier(recoverySession)
        let binding = appState.editorDocumentBinding(for: recoverySession)
        try "disk".write(to: fixture.url("post.md"), atomically: false, encoding: .utf8)

        try appState.activateFileSession(url: fixture.url("post.md"))

        XCTAssertEqual(appState.editorDocumentBindingIDs[recoveryIdentity], binding.id)
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[recoveryIdentity],
            .unavailable(fileURL: fixture.url("missing.md"))
        )
        appState.removeEditorDocumentBindingRegistration(for: recoverySession)
        XCTAssertNil(appState.unanchoredManagedSessionOwnershipProofs[recoveryIdentity])
    }

    /// Restores a detached text-recovery copy, fails its Close cleanup so the prompt offers
    /// Stop Tracking, and stops tracking it: the copy stays current but is no longer owned by
    /// any recovery record, cache entry, or retirement.
    private func stopTrackingRestoredRecovery(
        in appState: AppState,
        fixture: SessionStateCleanupFixture
    ) throws -> DocumentSession {
        let missingURL = fixture.url("missing.md")
        let record = WorkspaceMutationTextRecoveryRecord(
            originalURL: missingURL,
            fileKind: .markdown,
            source: "Recovered text",
            revision: 3,
            reason: .trash
        )
        appState.pendingWorkspaceMutationTextRecoveryRecords = [record]
        appState.restoreWorkspaceMutationTextRecoveryIfNeeded()
        let session = appState.shownSession
        let sessionIdentity = ObjectIdentifier(session)
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity],
            .unavailable(fileURL: missingURL)
        )

        fixture.recoveryStore.removeError = CocoaError(.fileWriteUnknown)
        appState.closeMissingFile()
        XCTAssertEqual(
            appState.workspaceMutationReconciliationPrompt?.secondaryAction,
            .stopTracking
        )
        appState.performWorkspaceMutationRecoverySecondaryAction()

        XCTAssertNil(appState.workspaceMutationTextRecoveryContexts[sessionIdentity])
        XCTAssertNil(appState.workspaceMutationTextRecoverySessions[record.id])
        XCTAssertTrue(appState.shownSession === session)
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity],
            .unavailable(fileURL: missingURL)
        )
        return session
    }

    func testAllDirtyEvictionSavesFailOncePerPassAndRetainUnsavedText() throws {
        let fixture = try SessionStateCleanupFixture()
        defer { fixture.cleanUp() }
        let appState = fixture.makeAppState(shownSession: DocumentSession())
        var sessions: [DocumentSession] = []
        // The shown document is installed and does not consume one of the 8 warm slots,
        // so nine dirty background sessions are what pushes the cache over the limit.
        for index in 0 ..< 10 {
            try "disk \(index)".write(to: fixture.url("\(index).md"), atomically: false, encoding: .utf8)
        }
        for index in 0 ..< 9 {
            try appState.activateFileSession(url: fixture.url("\(index).md"))
            let session = appState.shownSession
            appState.replaceDocumentText("unsaved \(index)")
            appState.cancelAutosave(for: session)
            XCTAssertEqual(appState.sessionStateURL(for: session), session.fileURL)
            XCTAssertEqual(appState.sessionPolicy.dirtyState(for: fixture.url("\(index).md")), true)
            sessions.append(session)
        }
        var attempts: [URL: Int] = [:]
        appState.anchoredFileSaveOverride = { _, location, _ in
            attempts[location.fileURL, default: 0] += 1
            // A failing old implementation must terminate the test instead of overflowing its stack.
            if attempts.values.reduce(0, +) > 16 {
                appState.sessionPolicy = .init(limit: 100)
            }
            throw CocoaError(.fileWriteNoPermission)
        }
        try appState.activateFileSession(url: fixture.url("9.md"))
        XCTAssertEqual(attempts.count, 9)
        XCTAssertTrue(attempts.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(appState.registry.sessionCache.count, 10)
        XCTAssertEqual(Set(appState.sessionPolicy.warmURLsInLeastRecentOrder), Set(appState.registry.sessionCache.keys))
        XCTAssertEqual(appState.presentedError?.title, "Could Not Save Warm File")
        for (index, session) in sessions.enumerated() {
            XCTAssertTrue(try appState.registry.sessionCache[XCTUnwrap(session.fileURL)] === session)
            XCTAssertTrue(session.isDirty)
            XCTAssertEqual(session.text, "unsaved \(index)")
            XCTAssertEqual(try String(contentsOf: fixture.url("\(index).md"), encoding: .utf8), "disk \(index)")
        }

        // The next independent pass may retry after storage recovers and restore the normal limit.
        appState.anchoredFileSaveOverride = nil
        appState.reconcileSessionPolicyAfterEditorLeaseChange()
        XCTAssertEqual(appState.registry.sessionCache.count, 9)
        XCTAssertEqual(appState.sessionPolicy.warmURLsInLeastRecentOrder.count, 9)
        XCTAssertEqual(sessions.filter { !$0.isDirty }.count, 1)
    }

    func testEvictionContinuesPastFailedSaveToCleanCandidate() throws {
        let fixture = try SessionStateCleanupFixture()
        defer { fixture.cleanUp() }
        let appState = fixture.makeAppState(shownSession: DocumentSession())
        appState.sessionPolicy = .init(limit: 2)
        for index in 0 ..< 4 {
            try "disk \(index)".write(to: fixture.url("\(index).md"), atomically: false, encoding: .utf8)
        }
        try appState.activateFileSession(url: fixture.url("0.md"))
        let dirty = appState.shownSession
        appState.replaceDocumentText("unsaved")
        appState.cancelAutosave(for: dirty)
        try appState.activateFileSession(url: fixture.url("1.md"))
        try appState.activateFileSession(url: fixture.url("2.md"))
        var attempts = 0
        appState.anchoredFileSaveOverride = { _, _, _ in
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        // The shown file is installed capacity. Three background sessions over a limit of
        // two make the failed dirty save stay, then the next clean candidate leave.
        try appState.activateFileSession(url: fixture.url("3.md"))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(appState.registry.sessionCache.count, 3)
        XCTAssertTrue(try appState.registry.sessionCache[XCTUnwrap(dirty.fileURL)] === dirty)
        XCTAssertNil(appState.registry.sessionCache[fixture.url("1.md")])
        XCTAssertNotNil(appState.registry.sessionCache[fixture.url("2.md")])
        XCTAssertTrue(dirty.isDirty)
        XCTAssertEqual(appState.shownSession.fileURL, fixture.url("3.md"))
    }

    func testDetachedRecoverySaveCopyPreservesReplacementURLState() throws {
        let fixture = try SessionStateCleanupFixture()
        defer { fixture.cleanUp() }
        let originalURL = fixture.url("post.md")
        let saveCopyURL = fixture.url("recovered.md")
        let recovery = DocumentSession(
            text: "Unsaved recovery text",
            url: originalURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = fixture.makeAppState(shownSession: recovery)

        try "Replacement text".write(
            to: originalURL,
            atomically: false,
            encoding: .utf8
        )
        let replacement = DocumentSession(
            text: "Replacement text",
            url: originalURL,
            fileKind: .markdown
        )
        appState.retainUnanchoredManagedSessionOwnership(for: replacement)
        appState.registry.sessionCache[originalURL] = replacement
        _ = appState.sessionPolicy.access(originalURL, isDirty: false)

        let recoveryID = UUID()
        let recoveryIdentity = ObjectIdentifier(recovery)
        appState.workspaceMutationTextRecoveryContexts[recoveryIdentity] =
            WorkspaceMutationTextRecoveryContext(
                recoveryID: recoveryID,
                originalURL: originalURL,
                fileKind: .markdown,
                reason: .trash,
                persistedRevision: recovery.version
            )
        appState.workspaceMutationTextRecoverySessions[recoveryID] = recovery

        let knownHash = "replacement-known-hash"
        let knownModificationDate = Date(timeIntervalSince1970: 1_725_000_000)
        let pendingExternalText = "replacement external text"
        appState.lastKnownDiskHashes[originalURL] = knownHash
        appState.lastKnownDiskModificationDates[originalURL] = knownModificationDate
        appState.pendingExternalTexts[originalURL] = pendingExternalText
        appState.detachedSessionURLs.insert(originalURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: originalURL)

        try appState.saveDetachedCurrentDocument(to: saveCopyURL)

        XCTAssertTrue(appState.registry.sessionCache[originalURL] === replacement)
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: originalURL), false)
        XCTAssertTrue(appState.sessionPolicy.warmURLsInLeastRecentOrder.contains(originalURL))
        XCTAssertTrue(appState.detachedSessionURLs.contains(originalURL))
        XCTAssertEqual(appState.lastKnownDiskHashes[originalURL], knownHash)
        XCTAssertEqual(
            appState.lastKnownDiskModificationDates[originalURL],
            knownModificationDate
        )
        XCTAssertEqual(appState.pendingExternalTexts[originalURL], pendingExternalText)
        XCTAssertEqual(
            try String(contentsOf: originalURL, encoding: .utf8),
            "Replacement text"
        )
        XCTAssertEqual(
            try String(contentsOf: saveCopyURL, encoding: .utf8),
            "Unsaved recovery text"
        )
        XCTAssertTrue(appState.registry.sessionCache[saveCopyURL] === recovery)
        XCTAssertNil(appState.workspaceMutationTextRecoveryContexts[recoveryIdentity])
        XCTAssertNil(appState.workspaceMutationTextRecoverySessions[recoveryID])
    }

    func testClearingRecoverySessionPreservesPromptsOwnedByReplacementSession() throws {
        let fixture = try SessionStateCleanupFixture()
        defer { fixture.cleanUp() }
        let originalURL = fixture.url("post.md")
        try "Replacement text".write(
            to: originalURL,
            atomically: false,
            encoding: .utf8
        )
        let replacement = DocumentSession(
            text: "Replacement text",
            url: originalURL,
            fileKind: .markdown
        )
        let appState = fixture.makeAppState(shownSession: replacement)
        let recovery = DocumentSession(
            text: "Recovery text",
            url: originalURL,
            fileKind: .markdown,
            isDirty: true
        )
        let recoveryID = UUID()
        let recoveryIdentity = ObjectIdentifier(recovery)
        appState.unanchoredManagedSessionOwnershipProofs[recoveryIdentity] =
            .unavailable(fileURL: originalURL)
        appState.workspaceMutationTextRecoveryContexts[recoveryIdentity] =
            WorkspaceMutationTextRecoveryContext(
                recoveryID: recoveryID,
                originalURL: originalURL,
                fileKind: .markdown,
                reason: .trash,
                persistedRevision: recovery.version
            )
        appState.workspaceMutationTextRecoverySessions[recoveryID] = recovery
        appState.registry.sessionCache[originalURL] = replacement
        _ = appState.sessionPolicy.access(originalURL, isDirty: false)
        appState.lastKnownDiskHashes[originalURL] = "replacement-known-hash"
        appState.pendingExternalTexts[originalURL] = "replacement external text"
        appState.detachedSessionURLs.insert(originalURL)
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: originalURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: originalURL)
        appState.indeterminateFileWriteReconciliationPrompt =
            IndeterminateFileWriteReconciliationPrompt(
                fileURL: originalURL,
                state: .unreadable
            )

        appState.clearSessionState(for: recovery, fallbackURL: originalURL)

        XCTAssertTrue(appState.registry.sessionCache[originalURL] === replacement)
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: originalURL), false)
        XCTAssertEqual(
            appState.lastKnownDiskHashes[originalURL],
            "replacement-known-hash"
        )
        XCTAssertEqual(
            appState.pendingExternalTexts[originalURL],
            "replacement external text"
        )
        XCTAssertTrue(appState.detachedSessionURLs.contains(originalURL))
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, originalURL)
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, originalURL)
        XCTAssertEqual(
            appState.indeterminateFileWriteReconciliationPrompt?.fileURL,
            originalURL
        )
    }
}

// swiftlint:enable function_body_length

@MainActor
private final class SessionStateCleanupFixture {
    let rootURL: URL
    private let userDefaults: UserDefaults
    private let userDefaultsSuiteName: String
    private let operationRecoveryStore = CleanupOperationRecoveryStore()
    let recoveryStore = SessionStateCleanupRecoveryStore()

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateSessionStateCleanupTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        userDefaultsSuiteName = "AppStateSessionStateCleanupTests.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: userDefaultsSuiteName))
    }

    func url(_ relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    func makeAppState(shownSession: DocumentSession) -> AppState {
        AppState(
            shownSession: shownSession,
            lastOpenedFileStore: SessionStateCleanupLastOpenedFileStore(),
            recentItemStore: SessionStateCleanupRecentItemStore(),
            workspaceMutationOperationRecoveryStore: operationRecoveryStore,
            workspaceMutationTextRecoveryStore: recoveryStore,
            shouldRestoreLastOpenedFile: false,
            userDefaults: userDefaults
        )
    }

    func cleanUp() {
        userDefaults.removePersistentDomain(
            forName: userDefaultsSuiteName
        )
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class SessionStateCleanupLastOpenedFileStore: LastOpenedFilePersisting {
    func save(_: URL) throws {}

    func restore() throws -> URL? {
        nil
    }
}

private final class SessionStateCleanupRecentItemStore: RecentItemPersisting {
    func save(_: URL) throws {}

    func restore() throws -> [URL] {
        []
    }
}

private final class SessionStateCleanupRecoveryStore: WorkspaceMutationTextRecoveryPersisting {
    private var records: [UUID: WorkspaceMutationTextRecoveryRecord] = [:]
    var removeError: Error?

    func load() throws -> [WorkspaceMutationTextRecoveryRecord] {
        Array(records.values)
    }

    func upsert(_ record: WorkspaceMutationTextRecoveryRecord) throws {
        records[record.id] = record
    }

    func remove(id: UUID) throws {
        if let removeError { throw removeError }
        records[id] = nil
    }

    func quarantine(id: UUID) throws {
        records[id] = nil
    }
}

private final class CleanupOperationRecoveryStore: WorkspaceMutationOperationRecoveryPersisting {
    private var records: [UUID: WorkspaceMutationOperationRecoveryRecord] = [:]

    func load() throws -> [WorkspaceMutationOperationRecoveryRecord] {
        Array(records.values)
    }

    func upsert(_ record: WorkspaceMutationOperationRecoveryRecord) throws {
        records[record.id] = record
    }

    func remove(id: UUID) throws {
        records[id] = nil
    }
}
