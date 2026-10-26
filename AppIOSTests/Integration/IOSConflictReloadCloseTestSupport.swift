import Foundation
import MarkdownCore
import WorkspaceCore
@testable import WorkspaceKitIOS

actor IOSConflictReloadCloseAccess: IOSCoordinatedFileAccess {
    private var blocksReads = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var hasBlockedRead = false

    func blockReads() {
        blocksReads = true
        hasBlockedRead = false
    }

    func releaseReads() {
        blocksReads = false
        let pending = readWaiters
        readWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func read(_ location: IOSFileLocation, lease _: any IOSWorkspaceAccessLease,
              operationID: UUID, maximumByteCount _: Int) async throws -> IOSCoordinatedRead
    {
        if blocksReads {
            hasBlockedRead = true
            await withCheckedContinuation { readWaiters.append($0) }
        }
        return IOSCoordinatedRead(operationID: operationID, location: location, data: Data("foreign 繁中".utf8))
    }

    func createNewLeaf(at _: IOSFileLocation, data _: Data, lease _: any IOSWorkspaceAccessLease,
                       operationID _: UUID) async throws -> IOSCreatedLeaf
    {
        throw IOSWorkspaceFailure.unavailable
    }

    func directorySnapshot(for _: IOSWorkspaceGrant, lease _: any IOSWorkspaceAccessLease,
                           requestID _: UUID) async throws -> IOSWorkspaceSnapshot
    {
        throw IOSWorkspaceFailure.unavailable
    }

    func events(for _: IOSWorkspaceGrant,
                lease _: any IOSWorkspaceAccessLease) async -> AsyncStream<IOSWorkspaceEvent>
    {
        AsyncStream { $0.finish() }
    }
}

actor IOSConflictReloadCloseRecovery: IOSRecoveryPersisting {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let store: IOSDocumentRecoveryStore
    private var blocksPersist = false
    private var persistWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var hasBlockedPersist = false

    init() {
        store = IOSDocumentRecoveryStore(directory: directory)
    }

    func blockPersist() {
        blocksPersist = true
        hasBlockedPersist = false
    }

    func releasePersist() {
        blocksPersist = false
        let pending = persistWaiters
        persistWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func persist(_ record: IOSRecoveryRecord) async throws -> IOSRecoveryReceipt {
        if blocksPersist {
            hasBlockedPersist = true
            await withCheckedContinuation { persistWaiters.append($0) }
        }
        return try await store.persist(record)
    }

    func list() async -> IOSRecoveryList {
        await store.list()
    }

    func load(_ recordID: UUID) async throws -> IOSRecoveryRecord {
        try await store.load(recordID)
    }

    func discard(recordID: UUID, persistedText: String, liveText: String, liveVersion: Int) async throws {
        try await store.discard(
            recordID: recordID, persistedText: persistedText, liveText: liveText, liveVersion: liveVersion
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
