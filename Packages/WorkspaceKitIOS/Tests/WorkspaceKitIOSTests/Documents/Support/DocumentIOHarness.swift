import Foundation
import MarkdownCore
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class ScriptedLease: IOSWorkspaceAccessLease {
    let grant: IOSWorkspaceGrant
    private(set) var isReleased = false

    init(grant: IOSWorkspaceGrant) {
        self.grant = grant
    }

    func release() {
        isReleased = true
    }
}

@MainActor
final class ScriptedFilePort: IOSDocumentFilePort {
    let fileURL: URL
    var openedData: Data
    var canWrite = true
    var openFailure: IOSDocumentFailure?
    var blockOpen = false
    /// Parks `create` after it writes, before it returns, like a provider notice racing it.
    var blockCreate = false
    var createExisting = false
    var failNextSave = false
    var indeterminateNextSave = false
    var blocksSaves = false
    var closeFailure: IOSDocumentFailure?
    var written: [Data] = []
    var inFlight = 0
    var peakInFlight = 0
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private(set) var parked = 0
    private var handler: (@MainActor (IOSDocumentFileEvent) -> Void)?
    private var completions: [UUID: @MainActor (IOSDocumentFileWriteDisposition) -> Void] = [:]
    var onSaveEntered: (() -> Void)?
    var closeGate: (@MainActor () async -> Void)?
    private(set) var closeCalls = 0
    private(set) var openCalls = 0

    init(fileURL: URL, openedData: Data) {
        self.fileURL = fileURL
        self.openedData = openedData
    }

    func setHandler(_ handler: (@MainActor @Sendable (IOSDocumentFileEvent) -> Void)?) {
        self.handler = handler
    }

    func emit(_ event: IOSDocumentFileEvent) {
        if case let .writePermissionChanged(writable) = event { canWrite = writable }
        handler?(event)
    }

    func open() async throws -> IOSDocumentFileOpenResult {
        openCalls += 1
        if blockOpen {
            await withCheckedContinuation { continuation in
                self.blocked.append(continuation)
                self.parked += 1
            }
        }
        if let openFailure {
            throw openFailure
        }
        return IOSDocumentFileOpenResult(data: openedData, canWrite: canWrite)
    }

    func create(snapshot: Data) async throws {
        if createExisting {
            throw IOSDocumentFailure.access(.alreadyExists)
        }
        written.append(snapshot)
        openedData = snapshot
        if blockCreate {
            await withCheckedContinuation { continuation in
                self.blocked.append(continuation)
                self.parked += 1
            }
        }
    }

    func save(
        snapshot: Data,
        operationID: UUID,
        completion: @escaping @MainActor @Sendable (IOSDocumentFileWriteDisposition) -> Void
    ) {
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        completions[operationID] = completion
        Task { @MainActor in
            if self.blocksSaves {
                await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                    self.blocked.append(gate)
                    self.parked += 1
                    self.onSaveEntered?()
                }
            }
            self.inFlight -= 1
            if self.indeterminateNextSave {
                self.indeterminateNextSave = false
                completion(.indeterminate)
                return
            }
            if self.failNextSave {
                self.failNextSave = false
                completion(.failed)
                return
            }
            self.written.append(snapshot)
            completion(.stored)
        }
    }

    func releaseOne() {
        guard !blocked.isEmpty else { return }
        blocked.removeFirst().resume()
    }

    func replay(_ operationID: UUID, disposition: IOSDocumentFileWriteDisposition = .stored) {
        completions[operationID]?(disposition)
    }

    func close() async throws {
        closeCalls += 1
        await closeGate?()
        if let closeFailure {
            throw closeFailure
        }
    }
}

@MainActor
final class ScriptedPortFactory {
    private(set) var created: [ScriptedFilePort] = []
    var openedData = Data("original".utf8)
    var canWrite = true
    var openFailure: IOSDocumentFailure?
    var blockOpen = false
    var blockCreate = false

    func make(fileURL: URL) -> ScriptedFilePort {
        let port = ScriptedFilePort(fileURL: fileURL, openedData: openedData)
        port.canWrite = canWrite
        port.openFailure = openFailure
        port.blockOpen = blockOpen
        port.blockCreate = blockCreate
        created.append(port)
        return port
    }

    func port(fileURL: URL) -> ScriptedFilePort? {
        let path = Data(fileURL.path(percentEncoded: false).utf8)
        return created.last { Data($0.fileURL.path(percentEncoded: false).utf8) == path }
    }
}

/// Not an actor: a MainActor caller passing a MainActor lease into an actor deadlocks.
final class ScriptedCoordinator: IOSCoordinatedFileAccess, @unchecked Sendable {
    private let stateLock = NSLock()
    private var bytes = Data("external".utf8)
    private var blockReads = false
    private var readFailure: IOSWorkspaceFailure?
    private var existingLeaves: Set<Data> = []
    private var created: [(Data, Data)] = []
    private var readGates: [CheckedContinuation<Void, Never>] = []
    private var blockedReadCount = 0
    private var readCount = 0
    private var readObserver: (@MainActor @Sendable () -> Void)?
    private var captureObserver: (@MainActor @Sendable () -> Void)?

    func setBytes(_ data: Data) async {
        stateLock.withLock { bytes = data }
    }

    func setBlockReads(_ blocked: Bool) async {
        stateLock.withLock { blockReads = blocked }
    }

    func setReadObserver(_ observer: (@MainActor @Sendable () -> Void)?) async {
        stateLock.withLock { readObserver = observer }
    }

    func setCaptureObserver(_ observer: (@MainActor @Sendable () -> Void)?) async {
        stateLock.withLock { captureObserver = observer }
    }

    func setReadFailure(_ failure: IOSWorkspaceFailure?) async {
        stateLock.withLock { readFailure = failure }
    }

    func blockedReads() async -> Int {
        stateLock.withLock { blockedReadCount }
    }

    func completedReads() async -> Int {
        stateLock.withLock { readCount }
    }

    func unblockReads() async {
        let gates = stateLock.withLock {
            let gates = readGates
            readGates.removeAll()
            return gates
        }
        for gate in gates {
            gate.resume()
        }
    }

    func seedExisting(_ key: Data) async {
        stateLock.withLock { _ = existingLeaves.insert(key) }
    }

    func removeExisting(_ key: Data) async {
        stateLock.withLock { _ = existingLeaves.remove(key) }
    }

    func createdLeaves() async -> [(Data, Data)] {
        stateLock.withLock { created }
    }

    func read(
        _ location: IOSFileLocation,
        lease _: any IOSWorkspaceAccessLease,
        operationID: UUID,
        maximumByteCount _: Int
    ) async throws -> IOSCoordinatedRead {
        let (shouldBlock, observer) = stateLock.withLock { (blockReads, readObserver) }
        await observer?()
        if shouldBlock {
            await withCheckedContinuation { continuation in
                self.stateLock.lock()
                self.readGates.append(continuation)
                self.blockedReadCount += 1
                self.stateLock.unlock()
            }
        }
        let (failure, payload, capturedObserver) = stateLock.withLock {
            if readFailure == nil {
                readCount += 1
            }
            return (readFailure, bytes, captureObserver)
        }
        await capturedObserver?()
        if let failure {
            throw failure
        }
        return IOSCoordinatedRead(operationID: operationID, location: location, data: payload)
    }

    func createNewLeaf(
        at location: IOSFileLocation,
        data: Data,
        lease _: any IOSWorkspaceAccessLease,
        operationID: UUID
    ) async throws -> IOSCreatedLeaf {
        let key = Data(location.relativePath.utf8)
        let exists = stateLock.withLock {
            let exists = existingLeaves.contains(key)
            if !exists {
                existingLeaves.insert(key)
                created.append((key, data))
            }
            return exists
        }
        if exists {
            throw IOSWorkspaceFailure.alreadyExists
        }
        return IOSCreatedLeaf(
            operationID: operationID,
            location: location,
            resourceID: IOSWorkspaceResourceIdentity(rawValue: key)
        )
    }

    func directorySnapshot(
        for _: IOSWorkspaceGrant,
        lease _: any IOSWorkspaceAccessLease,
        requestID _: UUID
    ) async throws -> IOSWorkspaceSnapshot {
        throw IOSWorkspaceFailure.unavailable
    }

    func events(
        for _: IOSWorkspaceGrant,
        lease _: any IOSWorkspaceAccessLease
    ) async -> AsyncStream<IOSWorkspaceEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

final class ScriptedRecovery: IOSRecoveryPersisting, @unchecked Sendable {
    private let stateLock = NSLock()
    private var failNext = false
    private var records: [UUID: IOSRecoveryRecord] = [:]

    func setFailNext(_ fail: Bool) async {
        stateLock.withLock { failNext = fail }
    }

    func persist(_ record: IOSRecoveryRecord) async throws -> IOSRecoveryReceipt {
        let shouldFail = stateLock.withLock {
            let shouldFail = failNext
            if shouldFail {
                failNext = false
            } else {
                records[record.recordID] = record
            }
            return shouldFail
        }
        if shouldFail {
            throw IOSDocumentFailure.recoveryFailed
        }
        return IOSRecoveryReceipt(
            operationID: record.operationID,
            revision: IOSDocumentRevision(
                documentID: IOSDocumentIdentity(rawValue: record.documentID),
                version: record.revisionVersion
            ),
            recordID: record.recordID
        )
    }

    func list() async -> IOSRecoveryList {
        let values = stateLock.withLock { Array(records.values) }
        return IOSRecoveryList(records: values, corruptNames: [])
    }

    func load(_ recordID: UUID) async throws -> IOSRecoveryRecord {
        let record = stateLock.withLock { records[recordID] }
        guard let record else { throw IOSRecoveryDiscardError.missing }
        return record
    }

    func discard(recordID: UUID, persistedText: String, liveText: String, liveVersion: Int) async throws {
        let record = stateLock.withLock { records[recordID] }
        guard let record else { throw IOSRecoveryDiscardError.missing }
        guard ExactSourceText.matches(persistedText, record.source) else {
            throw IOSRecoveryDiscardError.contentNotConfirmed
        }
        if liveVersion > record.revisionVersion, !ExactSourceText.matches(liveText, record.source) {
            throw IOSRecoveryDiscardError.newerLocalRevision
        }
        stateLock.withLock { records[recordID] = nil }
    }

    func discardSuperseded(recordID: UUID, documentID: UUID, newerVersion: Int) async throws {
        try stateLock.withLock {
            guard let record = records[recordID] else { throw IOSRecoveryDiscardError.missing }
            guard record.documentID == documentID, record.revisionVersion < newerVersion else {
                throw IOSRecoveryDiscardError.newerLocalRevision
            }
            records[recordID] = nil
        }
    }
}

@MainActor
final class DocumentIOHarness {
    let root: URL
    let workspaceID = IOSWorkspaceIdentity(rawValue: UUID())
    let coordinator = ScriptedCoordinator()
    let recovery: any IOSRecoveryPersisting
    let ports = ScriptedPortFactory()
    let store: IOSUIDocumentStore
    private(set) var events: [IOSDocumentEvent] = []
    private var observation: (any IOSObservation)?

    init(recovery: any IOSRecoveryPersisting = ScriptedRecovery(), timing: IOSDocumentTiming = .quiet) {
        self.recovery = recovery
        root = Self.exactFileURL("/private/tmp/plainsong-doc-io/\(UUID().uuidString)")
        let ports = ports
        store = IOSUIDocumentStore(
            coordinatedAccess: coordinator,
            recovery: recovery,
            timing: timing,
            filePortFactory: { url in ports.make(fileURL: url) }
        )
        observation = store.observe { [weak self] event in
            self?.events.append(event)
        }
    }

    func directoryLease(generation: UInt64) -> ScriptedLease {
        ScriptedLease(
            grant: IOSWorkspaceGrant(
                workspaceID: workspaceID,
                rootURL: root,
                accessGeneration: generation,
                scope: .directory
            )
        )
    }

    func location(
        relativePath: String,
        generation: UInt64,
        resourceID: Data? = Data("resource".utf8)
    ) -> IOSFileLocation {
        let base = root.path(percentEncoded: false)
        let separator = base.hasSuffix("/") ? "" : "/"
        return IOSFileLocation(
            workspaceID: workspaceID,
            accessGeneration: generation,
            relativePath: relativePath,
            fileURL: Self.exactFileURL(base + separator + relativePath),
            resourceID: resourceID.map { IOSWorkspaceResourceIdentity(rawValue: $0) }
        )
    }

    /// Keeps the exact UTF-8 spelling. `URL(fileURLWithPath:)` can normalize Unicode.
    static func exactFileURL(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = "file"
        components.path = path
        return components.url ?? URL(fileURLWithPath: path)
    }

    func openNote(
        text: String = "original",
        generation: UInt64 = 1,
        relativePath: String = "Note.md",
        resourceID: Data? = Data("resource".utf8),
        canWrite: Bool = true
    ) async throws -> IOSDocumentHandle {
        let location = location(relativePath: relativePath, generation: generation, resourceID: resourceID)
        ports.openedData = Data(text.utf8)
        ports.canWrite = canWrite
        return try await store.open(location, lease: directoryLease(generation: generation))
    }

    func port(for handle: IOSDocumentHandle) -> ScriptedFilePort? {
        ports.port(fileURL: handle.location.fileURL)
    }
}

extension IOSDocumentTiming {
    static let quiet = IOSDocumentTiming(
        autosaveDelayNanoseconds: 60_000_000_000,
        backgroundFlushNanoseconds: 40_000_000
    )

    static let fastAutosave = IOSDocumentTiming(
        autosaveDelayNanoseconds: 20_000_000,
        backgroundFlushNanoseconds: 40_000_000
    )
}
