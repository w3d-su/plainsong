import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

// swiftlint:disable function_body_length
@MainActor
final class AppStateSessionStateCleanupTests: XCTestCase {
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
        let appState = fixture.makeAppState(currentDocument: recovery)

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
        appState.sessionCache[originalURL] = replacement
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

        XCTAssertTrue(appState.sessionCache[originalURL] === replacement)
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
        XCTAssertTrue(appState.sessionCache[saveCopyURL] === recovery)
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
        let appState = fixture.makeAppState(currentDocument: replacement)
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
        appState.sessionCache[originalURL] = replacement
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

        XCTAssertTrue(appState.sessionCache[originalURL] === replacement)
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
    private let recoveryStore = SessionStateCleanupRecoveryStore()

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

    func makeAppState(currentDocument: DocumentSession) -> AppState {
        AppState(
            currentDocument: currentDocument,
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

    func load() throws -> [WorkspaceMutationTextRecoveryRecord] {
        Array(records.values)
    }

    func upsert(_ record: WorkspaceMutationTextRecoveryRecord) throws {
        records[record.id] = record
    }

    func remove(id: UUID) throws {
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
