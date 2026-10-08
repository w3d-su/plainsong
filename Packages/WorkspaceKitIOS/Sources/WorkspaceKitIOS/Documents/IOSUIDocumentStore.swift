import Foundation
import MarkdownCore
import WorkspaceCore

/// UIDocument-backed document store. The canonical text is the entry's `DocumentSession`.
/// Save completions rebase that baseline and never replace live source.
@MainActor
public final class IOSUIDocumentStore: IOSDocumentStore {
    let coordinatedAccess: any IOSCoordinatedFileAccess
    let recovery: any IOSRecoveryPersisting
    let timing: IOSDocumentTiming
    let filePortFactory: @MainActor (URL) -> any IOSDocumentFilePort
    var byResource: [IOSDocumentResourceKey: IOSDocumentEntry] = [:]
    var byIdentity: [IOSDocumentIdentity: IOSDocumentEntry] = [:]
    var observations: [UUID: IOSDocumentStoreObservation] = [:]
    let maximumExternalBytes = 16 * 1024 * 1024

    public convenience init(
        coordinatedAccess: any IOSCoordinatedFileAccess,
        recoveryDirectory: URL,
        timing: IOSDocumentTiming = .production
    ) {
        self.init(
            coordinatedAccess: coordinatedAccess,
            recovery: IOSDocumentRecoveryStore(directory: recoveryDirectory),
            timing: timing,
            filePortFactory: { url in UIDocumentFileAdapter(fileURL: url) }
        )
    }

    init(
        coordinatedAccess: any IOSCoordinatedFileAccess,
        recovery: any IOSRecoveryPersisting,
        timing: IOSDocumentTiming,
        filePortFactory: @escaping @MainActor (URL) -> any IOSDocumentFilePort
    ) {
        self.coordinatedAccess = coordinatedAccess
        self.recovery = recovery
        self.timing = timing
        self.filePortFactory = filePortFactory
    }

    public func open(
        _ location: IOSFileLocation,
        lease: any IOSWorkspaceAccessLease
    ) async throws -> IOSDocumentHandle {
        try Task.checkCancellation()
        try validate(location, lease: lease)
        return try await load(location, lease: lease, creating: nil)
    }

    public func create(
        at location: IOSFileLocation,
        initialText: String,
        lease: any IOSWorkspaceAccessLease
    ) async throws -> IOSDocumentHandle {
        try Task.checkCancellation()
        try validate(location, lease: lease)
        return try await load(location, lease: lease, creating: initialText)
    }

    public func state(for identity: IOSDocumentIdentity) -> IOSDocumentState? {
        byIdentity[identity]?.state
    }

    public func snapshot(for identity: IOSDocumentIdentity) -> IOSStoredDocumentSnapshot? {
        guard let entry = byIdentity[identity] else { return nil }
        return storedSnapshot(entry)
    }

    public func observe(
        _ handler: @escaping @MainActor (IOSDocumentEvent) -> Void
    ) -> any IOSObservation {
        let observation = IOSDocumentStoreObservation(handler: handler)
        observations[observation.token] = observation
        return observation
    }

    public func recoveryList() async -> IOSRecoveryList {
        await recovery.list()
    }

    public func discardRecovery(
        recordID: UUID,
        persistedText: String,
        liveText: String,
        liveVersion: Int
    ) async throws {
        try await recovery.discard(
            recordID: recordID,
            persistedText: persistedText,
            liveText: liveText,
            liveVersion: liveVersion
        )
    }

    func validate(_ location: IOSFileLocation, lease: any IOSWorkspaceAccessLease) throws {
        if lease.isReleased {
            throw IOSDocumentFailure.access(.grantChanged)
        }
        if IOSDocumentLocationGuard.recognizedDocumentExtension(location.relativePath) == nil {
            throw IOSDocumentFailure.access(.unsupportedType)
        }
        if !IOSDocumentLocationGuard.authorize(location: location, grant: lease.grant) {
            throw IOSDocumentFailure.access(.outsideGrant)
        }
    }

    func load(
        _ location: IOSFileLocation,
        lease: any IOSWorkspaceAccessLease,
        creating initialText: String?
    ) async throws -> IOSDocumentHandle {
        let key = IOSDocumentResourceKey(location: location)
        if let existing = byResource[key] {
            let sameAuthority = existing.accessGeneration == location.accessGeneration
                && !existing.superseded
                && !existing.closed
            if sameAuthority {
                if initialText != nil {
                    throw IOSDocumentFailure.access(.alreadyExists)
                }
                return try await existing.awaitReady()
            }
            supersede(existing)
        }

        let entry = makeEntry(location: location, lease: lease, key: key)
        byResource[key] = entry
        byIdentity[entry.identity] = entry
        emitState(entry)
        do {
            let text: String
            let canWrite: Bool
            if let initialText {
                try await entry.filePort.create(snapshot: IOSDocumentTextCodec.encode(initialText))
                text = initialText
                canWrite = true
            } else {
                let opened = try await entry.filePort.open()
                guard let decoded = IOSDocumentTextCodec.decode(opened.data) else {
                    throw IOSDocumentFailure.access(.unsupportedType)
                }
                text = decoded
                canWrite = opened.canWrite
            }
            try Task.checkCancellation()
            guard guardCurrentAuthority(entry, generation: entry.accessGeneration) else {
                throw IOSDocumentFailure.documentChanged
            }
            installSession(entry, text: text, canWrite: canWrite && !entry.lease.isReleased)
            guard let handle = entry.handle() else {
                throw IOSDocumentFailure.unavailable
            }
            finishOpen(entry, result: .success(handle))
            return handle
        } catch {
            if error is CancellationError {
                failOpen(entry, .unavailable)
                throw error
            }
            let failure = (mapped(error) as? IOSDocumentFailure) ?? .unavailable
            failOpen(entry, failure)
            throw failure
        }
    }

    func makeEntry(
        location: IOSFileLocation,
        lease: any IOSWorkspaceAccessLease,
        key: IOSDocumentResourceKey
    ) -> IOSDocumentEntry {
        let port = filePortFactory(location.fileURL)
        let entry = IOSDocumentEntry(
            identity: IOSDocumentIdentity(rawValue: UUID()),
            resourceKey: key,
            location: location,
            lease: lease,
            filePort: port,
            allowsProviderWrite: true
        )
        port.setHandler { [weak self, weak entry] event in
            guard let self, let entry else { return }
            handleFileEvent(event, entry: entry)
        }
        return entry
    }

    func installSession(_ entry: IOSDocumentEntry, text: String, canWrite: Bool) {
        let fileKind = FileKind(url: entry.location.fileURL) ?? .markdown
        let session = DocumentSession(
            text: text,
            url: entry.location.fileURL,
            fileKind: fileKind,
            isDirty: false
        )
        entry.session = session
        entry.lastPersistedText = text
        entry.allowsProviderWrite = canWrite
        entry.openFinished = true
        setState(.ready(canWrite: canWrite, accessGeneration: entry.accessGeneration), entry: entry)
        emitSnapshot(entry)
        watchEdits(entry)
    }

    func finishOpen(_ entry: IOSDocumentEntry, result: Result<IOSDocumentHandle, Error>) {
        entry.openFinished = true
        if case let .failure(error) = result {
            entry.openFailure = error
        }
        let waiters = entry.openWaiters
        entry.openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    func failOpen(_ entry: IOSDocumentEntry, _ failure: IOSDocumentFailure) {
        entry.allowsProviderWrite = false
        entry.fenced = true
        setState(.unavailable(accessGeneration: entry.accessGeneration, reason: failure), entry: entry)
        emit(.failed(entry.identity, operationID: UUID(), reason: failure))
        if byResource[entry.resourceKey] === entry {
            byResource[entry.resourceKey] = nil
        }
        byIdentity[entry.identity] = nil
        finishOpen(entry, result: .failure(failure))
    }

    func supersede(_ entry: IOSDocumentEntry) {
        entry.superseded = true
        entry.fenced = true
        entry.allowsProviderWrite = false
        entry.externalToken = nil
        entry.autosaveTask?.cancel()
        if byResource[entry.resourceKey] === entry {
            byResource[entry.resourceKey] = nil
        }
    }

    func guardCurrentAuthority(_ entry: IOSDocumentEntry, generation: UInt64) -> Bool {
        if entry.superseded || entry.closed {
            return false
        }
        if byResource[entry.resourceKey] !== entry {
            return false
        }
        if entry.accessGeneration != generation {
            return false
        }
        if entry.lease.isReleased {
            return false
        }
        if entry.lease.grant.accessGeneration != generation {
            return false
        }
        if entry.lease.grant.workspaceID != entry.location.workspaceID {
            return false
        }
        return true
    }

    func setState(_ state: IOSDocumentState, entry: IOSDocumentEntry) {
        entry.state = state
        emitState(entry)
    }

    func emitState(_ entry: IOSDocumentEntry) {
        emit(.stateChanged(identity: entry.identity, location: entry.location, state: entry.state))
    }

    func emitSnapshot(_ entry: IOSDocumentEntry) {
        guard let snapshot = storedSnapshot(entry) else { return }
        emit(.snapshotChanged(snapshot))
    }

    func storedSnapshot(_ entry: IOSDocumentEntry) -> IOSStoredDocumentSnapshot? {
        guard let session = entry.session else { return nil }
        return IOSStoredDocumentSnapshot(
            revision: IOSDocumentRevision(documentID: entry.identity, version: session.version),
            document: session.snapshot,
            location: entry.location,
            state: entry.state
        )
    }

    func emit(_ event: IOSDocumentEvent) {
        for observation in observations.values {
            observation.handler?(event)
        }
    }

    func mapped(_ error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        if error is IOSDocumentFailure {
            return error
        }
        if let workspace = error as? IOSWorkspaceFailure {
            return IOSDocumentFailure.access(workspace)
        }
        return IOSDocumentFailure.unavailable
    }

    func requireEntry(_ identity: IOSDocumentIdentity) throws -> IOSDocumentEntry {
        guard let entry = byIdentity[identity], !entry.closed, !entry.superseded, entry.session != nil else {
            throw IOSDocumentFailure.unavailable
        }
        return entry
    }
}
