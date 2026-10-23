import Foundation
import MarkdownCore
import PreviewKitContracts
import WorkspaceCore

/// Files / iCloud access service. Grants, leases, bookmarks, and snapshots live here.
/// Document bytes stay with lane 05. Production composition stays unavailable until M0.
@MainActor
public final class IOSWorkspaceAccessService: IOSWorkspaceAccessProviding, PreviewAssetAccessChecking {
    let ports: IOSWorkspaceAccessPorts
    var records: [IOSWorkspaceIdentity: IOSWorkspaceScopeRecord] = [:]
    var observations: [UUID: IOSWorkspaceObservation] = [:]
    var ownedAssets: [UUID: IOSOwnedAssetRecord] = [:]
    var pendingNotices: [String: IOSQueuedWorkspaceNotice] = [:]
    var persistedLeaves: [UUID: IOSPersistedLeaf] = [:]
    var noticeFlushScheduled = false
    var recentRestoreRequests: [UUID: UUID] = [:]
    public var includesHiddenEntries = false
    public var includesAllFiles = false
    let maximumRecentItems = 10

    init(ports: IOSWorkspaceAccessPorts) {
        self.ports = ports
    }

    public func open(selectedURL: URL, scope: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant {
        try Task.checkCancellation()
        return try await adopt(
            url: selectedURL,
            scope: scope,
            provenance: .userSelection,
            bookmark: nil,
            replacingGeneration: nil
        )
    }

    public func restore(bookmark: Data, scope: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant {
        try Task.checkCancellation()
        let resolution: IOSBookmarkResolution
        do {
            resolution = try ports.bookmarks.resolve(bookmark)
        } catch {
            markBookmark(bookmark, status: .needsReselection)
            throw IOSWorkspaceFailureMapping.map(error)
        }
        // LANE06_GUARD_DENIED_BOOKMARK
        if let failure = resolution.failure {
            if failure == .offline {
                throw IOSWorkspaceFailure.offline
            }
            markBookmark(bookmark, status: .needsReselection)
            throw failure
        }
        guard let url = resolution.url else {
            markBookmark(bookmark, status: .needsReselection)
            throw IOSWorkspaceFailure.permissionDenied
        }
        var storedBookmark = bookmark
        if resolution.isStale {
            storedBookmark = try ports.bookmarks.bookmark(for: url)
            replaceBookmark(bookmark, with: storedBookmark)
        }
        return try await adopt(
            url: url,
            scope: scope,
            provenance: .bookmarkRestore,
            bookmark: storedBookmark,
            replacingGeneration: nil
        )
    }

    public func acquireLease(for grant: IOSWorkspaceGrant) throws -> any IOSWorkspaceAccessLease {
        guard let record = records[grant.workspaceID] else {
            throw IOSWorkspaceFailure.grantChanged
        }
        guard record.generation == grant.accessGeneration, !record.revoked, !record.stopped else {
            throw IOSWorkspaceFailure.grantChanged
        }
        guard IOSWorkspacePathAuthority.sameFile(record.rootURL, grant.rootURL), record.scope == grant.scope else {
            throw IOSWorkspaceFailure.outsideGrant
        }
        record.addConsumer()
        return IOSRetainedAccessLease(grant: record.grant, service: self)
    }

    public func invalidate(_ identity: IOSWorkspaceIdentity) -> UInt64 {
        guard let record = records[identity] else { return 0 }
        record.generation &+= 1
        record.latestRequestID = nil
        record.revoked = true
        let generation = record.generation
        publish(.invalidated(workspaceID: identity, generation: generation))
        stopIfIdle(record)
        return generation
    }

    public func currentGrant(for identity: IOSWorkspaceIdentity) -> IOSWorkspaceGrant? {
        guard let record = records[identity], !record.stopped else { return nil }
        return record.grant
    }

    /// Live grant check. A retained lease keeps a generation snapshot and its
    /// security scope so an in-flight provider call can drain; that snapshot
    /// does not authorize a new document operation after invalidate.
    func authorizes(workspaceID: IOSWorkspaceIdentity, generation: UInt64) -> Bool {
        guard let record = records[workspaceID] else { return false }
        return record.generation == generation && !record.revoked && !record.stopped
    }

    public func snapshot(for identity: IOSWorkspaceIdentity) -> IOSWorkspaceSnapshot? {
        records[identity]?.latestSnapshot
    }

    public func refresh(_ grant: IOSWorkspaceGrant) async throws -> IOSWorkspaceSnapshot {
        let requestID = UUID()
        let lease = try acquireLease(for: grant)
        defer { lease.release() }
        return try await directorySnapshot(for: grant, lease: lease, requestID: requestID)
    }

    public func observe(
        _ handler: @escaping @MainActor (IOSWorkspaceEvent) -> Void
    ) -> any IOSObservation {
        let observation = IOSWorkspaceObservation(handler: handler)
        observations[observation.token] = observation
        return observation
    }

    public func isCurrent(_ context: PreviewAssetAccessContext) -> Bool {
        matchingRecord(context) != nil
    }

    public func recentItems() -> [IOSRecentWorkspaceItem] {
        ports.recents.load().map(\.item)
    }

    public func removeRecent(recordID: UUID) {
        recentRestoreRequests[recordID] = nil
        var items = ports.recents.load()
        items.removeAll { $0.recordID == recordID }
        ports.recents.save(items)
    }

    public func expansionState(for workspaceID: IOSWorkspaceIdentity) -> WorkspaceExpansionState? {
        records[workspaceID]?.expansion
    }

    public func updateExpansion(_ state: WorkspaceExpansionState) throws {
        guard let record = records[state.workspaceID], record.generation == state.accessGeneration else {
            throw IOSWorkspaceFailure.grantChanged
        }
        record.expansion = state
    }

    public func previewContext(for grant: IOSWorkspaceGrant) -> PreviewAssetAccessContext? {
        guard let record = records[grant.workspaceID], record.generation == grant.accessGeneration else {
            return nil
        }
        return PreviewAssetAccessContext(
            allowedRoot: record.rootURL,
            rootToken: record.rootToken,
            grantIdentity: record.workspaceID.rawValue,
            accessGeneration: record.generation
        )
    }

    func ingest(_ notice: IOSQueuedWorkspaceNotice) {
        pendingNotices[notice.coalesceKey] = notice
        guard !noticeFlushScheduled else { return }
        noticeFlushScheduled = true
        Task { @MainActor in
            self.flushNotices()
        }
    }

    func releaseConsumer(_ lease: IOSRetainedAccessLease) {
        guard let record = records[lease.grant.workspaceID] else { return }
        // LANE06_GUARD_CONSUMER_COUNT
        if record.consumerCount > 0 {
            record.consumerCount -= 1
        }
        stopIfIdle(record)
    }

    func adopt(
        url: URL,
        scope: IOSWorkspaceScope,
        provenance: IOSAccessProvenance,
        bookmark explicitBookmark: Data?,
        replacingGeneration: UInt64?
    ) async throws -> IOSWorkspaceGrant {
        guard url.isFileURL else { throw IOSWorkspaceFailure.invalidPath }
        let admission = ports.scope.begin(url: url, provenance: provenance)
        if admission == .denied {
            throw IOSWorkspaceFailure.permissionDenied
        }
        let displayName = url.lastPathComponent
        let relative = displayName.isEmpty ? "file" : displayName
        do {
            let item = try await metadataForAdopt(url: url, relativePath: relative, admission: admission)
            if scope == .directory, !item.isDirectory {
                throw IOSWorkspaceFailure.invalidPath
            }
            if scope == .singleFile, item.isDirectory {
                throw IOSWorkspaceFailure.invalidPath
            }
            if item.isSymlink {
                throw IOSWorkspaceFailure.outsideGrant
            }
            let providerIdentity = acceptedIdentity(ports.identity.identity(for: url, relativePath: relative))
            let bookmark = try explicitBookmark ?? ports.bookmarks.bookmark(for: url)
            let record = IOSWorkspaceScopeRecord(
                workspaceID: IOSWorkspaceIdentity(rawValue: UUID()),
                rootURL: url,
                scope: scope,
                rootToken: UUID(),
                displayName: displayName,
                generation: replacingGeneration ?? 1
            )
            record.providerIdentity = providerIdentity
            record.mustStop = admission == .started
            record.bookmark = bookmark
            records[record.workspaceID] = record
            remember(record: record, bookmark: bookmark)
            startWatching(record)
            return record.grant
        } catch let draining as IOSDrainingCoordinationFailure {
            try throwDraining(draining)
        } catch {
            if admission == .started {
                ports.scope.end(url: url)
            }
            throw error
        }
    }

    func acceptedIdentity(_ identity: Data?) -> Data? {
        guard let identity, !identity.isEmpty else { return nil }
        return identity
    }

    func matchingRecord(_ context: PreviewAssetAccessContext) -> IOSWorkspaceScopeRecord? {
        let identity = IOSWorkspaceIdentity(rawValue: context.grantIdentity)
        guard let record = records[identity] else { return nil }
        guard record.rootToken == context.rootToken else { return nil }
        guard record.generation == context.accessGeneration, !record.stopped else { return nil }
        guard IOSWorkspacePathAuthority.sameFile(record.rootURL, context.allowedRoot) else { return nil }
        return record
    }

    func record(for lease: any IOSWorkspaceAccessLease) throws -> IOSWorkspaceScopeRecord {
        if lease.isReleased {
            throw IOSWorkspaceFailure.grantChanged
        }
        guard let record = records[lease.grant.workspaceID] else {
            throw IOSWorkspaceFailure.grantChanged
        }
        guard record.generation == lease.grant.accessGeneration else {
            throw IOSWorkspaceFailure.grantChanged
        }
        guard !record.stopped else { throw IOSWorkspaceFailure.permissionDenied }
        return record
    }

    func admit(
        location: IOSFileLocation,
        lease: any IOSWorkspaceAccessLease,
        operationID: UUID,
        requestID: UUID?
    ) throws -> IOSOperationTicket {
        let record = try record(for: lease)
        guard location.workspaceID == record.workspaceID else { throw IOSWorkspaceFailure.outsideGrant }
        guard location.accessGeneration == record.generation else { throw IOSWorkspaceFailure.grantChanged }
        try authorize(location, record: record)
        if let requestID {
            record.latestRequestID = requestID
        }
        record.addOperation()
        return IOSOperationTicket(
            workspaceID: record.workspaceID,
            generation: record.generation,
            rootToken: record.rootToken,
            operationID: operationID,
            requestID: requestID
        )
    }

    func authorize(_ location: IOSFileLocation, record: IOSWorkspaceScopeRecord) throws {
        guard location.fileURL.isFileURL else { throw IOSWorkspaceFailure.invalidPath }
        // LANE06_GUARD_SINGLE_FILE_SCOPE
        if record.scope == .singleFile {
            guard IOSWorkspacePathAuthority.sameFile(record.rootURL, location.fileURL) else {
                throw IOSWorkspaceFailure.outsideGrant
            }
            guard WorkspaceRelativePath(spelling: location.relativePath) != nil else {
                throw IOSWorkspaceFailure.invalidPath
            }
            return
        }
        guard IOSWorkspacePathAuthority.directoryContains(
            root: record.rootURL,
            file: location.fileURL,
            relativePath: location.relativePath
        ) else {
            throw IOSWorkspaceFailure.outsideGrant
        }
    }

    func accept(_ ticket: IOSOperationTicket) throws -> IOSWorkspaceScopeRecord {
        guard let record = records[ticket.workspaceID] else {
            throw IOSWorkspaceFailure.grantChanged
        }
        // LANE06_GUARD_GENERATION
        guard ticket.generation == record.generation, ticket.rootToken == record.rootToken else {
            throw IOSWorkspaceFailure.grantChanged
        }
        if let requestID = ticket.requestID, record.latestRequestID != requestID {
            throw IOSWorkspaceFailure.grantChanged
        }
        return record
    }

    func finish(_ ticket: IOSOperationTicket) {
        guard let record = records[ticket.workspaceID] else { return }
        if record.operationCount > 0 {
            record.operationCount -= 1
        }
        stopIfIdle(record)
    }

    /// Holds the scope for a port call that continues after the caller returns.
    /// A revoked grant can still take the hold. `finish` releases it.
    func retainOperation(workspaceID: IOSWorkspaceIdentity) -> IOSOperationTicket? {
        guard let record = records[workspaceID], !record.stopped else { return nil }
        record.addOperation()
        return IOSOperationTicket(
            workspaceID: record.workspaceID,
            generation: record.generation,
            rootToken: record.rootToken,
            operationID: UUID(),
            requestID: nil
        )
    }

    func stopIfIdle(_ record: IOSWorkspaceScopeRecord) {
        guard record.revoked, record.isIdle, !record.stopped else { return }
        record.stopped = true
        ports.watcher.stop(identity: record.workspaceID)
        if record.mustStop {
            ports.scope.end(url: record.rootURL)
        }
    }

    func startWatching(_ record: IOSWorkspaceScopeRecord) {
        let identity = record.workspaceID
        let generation = record.generation
        let rootToken = record.rootToken
        ports.watcher.start(root: record.rootURL, identity: identity) { [weak self] notice in
            let queued = IOSQueuedWorkspaceNotice(
                workspaceID: identity,
                generation: generation,
                rootToken: rootToken,
                notice: notice
            )
            Task { @MainActor in
                self?.ingest(queued)
            }
        }
    }

    func publish(_ event: IOSWorkspaceEvent) {
        let handlers = observations.values.compactMap(\.handler)
        for handler in handlers {
            handler(event)
        }
    }

    func publishSnapshot(_ snapshot: IOSWorkspaceSnapshot, record: IOSWorkspaceScopeRecord) throws {
        let application = WorkspaceSnapshotReconciler.reconcile(
            previous: record.expansion,
            snapshot: snapshot
        )
        switch application {
        case let .applied(_, state):
            record.expansion = state
            record.latestSnapshot = snapshot
            publish(.snapshotChanged(snapshot))
        case .rejectedStaleGeneration:
            throw IOSWorkspaceFailure.grantChanged
        }
    }
}
