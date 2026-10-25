import Foundation
import MarkdownCore
import WorkspaceCore

extension IOSWorkspaceAccessService {
    func location(
        record: IOSWorkspaceScopeRecord,
        relativePath: String,
        fileURL: URL,
        identity: Data?
    ) -> IOSFileLocation? {
        guard WorkspaceRelativePath(spelling: relativePath) != nil else { return nil }
        let resourceID = identity.map { IOSWorkspaceResourceIdentity(rawValue: $0) }
        return IOSFileLocation(
            workspaceID: record.workspaceID,
            accessGeneration: record.generation,
            relativePath: relativePath,
            fileURL: fileURL,
            resourceID: resourceID
        )
    }

    func fileURL(record: IOSWorkspaceScopeRecord, relativePath: String) -> URL {
        if record.scope == .singleFile {
            return record.rootURL
        }
        return IOSWorkspacePathAuthority.fileURL(
            path: IOSWorkspacePathAuthority.joined(root: record.rootURL, relativePath: relativePath)
        )
    }

    func remember(record: IOSWorkspaceScopeRecord, bookmark: Data) {
        var items = ports.recents.load()
        let matchingIDs = Set(items.filter { matchesRecent($0, record: record) }.map(\.recordID))
        let recentID = items.first { matchingIDs.contains($0.recordID) }?.recordID ?? UUID()
        items.removeAll { matchingIDs.contains($0.recordID) }
        items.insert(
            IOSStoredRecentWorkspace(
                recordID: recentID,
                displayName: record.displayName,
                scope: record.scope,
                openedAt: ports.clock(),
                providerIdentity: record.providerIdentity,
                status: .available,
                bookmark: bookmark,
                metadataPath: Data(IOSWorkspacePathAuthority.pathBytes(record.rootURL))
            ),
            at: 0
        )
        if items.count > maximumRecentItems {
            items.removeLast(items.count - maximumRecentItems)
        }
        ports.recents.save(items)
    }

    /// List identity is not access authority. In particular, a known path does
    /// not permit restore without resolving the stored bookmark and a fresh grant.
    func matchesRecent(_ item: IOSStoredRecentWorkspace, record: IOSWorkspaceScopeRecord) -> Bool {
        guard item.scope == record.scope else { return false }
        if let identity = record.providerIdentity, item.providerIdentity == identity {
            return true
        }
        let selectedPath = Data(IOSWorkspacePathAuthority.pathBytes(record.rootURL))
        if let path = item.metadataPath {
            return path == selectedPath
        }
        // Legacy stores contain only bookmarks. Resolution here supplies metadata
        // for deduplication; it does not start a scope or create an access record.
        guard let resolution = try? ports.bookmarks.resolve(item.bookmark),
              resolution.failure == nil, let url = resolution.url, url.isFileURL
        else { return false }
        return Data(IOSWorkspacePathAuthority.pathBytes(url)) == selectedPath
    }

    func markBookmark(_ bookmark: Data, status: IOSRecentWorkspaceStatus) {
        var items = ports.recents.load()
        var changed = false
        for index in items.indices where items[index].bookmark == bookmark {
            items[index].status = status
            changed = true
        }
        if changed {
            ports.recents.save(items)
        }
    }

    func replaceBookmark(_ bookmark: Data, with refreshed: Data) {
        var items = ports.recents.load()
        var changed = false
        for index in items.indices where items[index].bookmark == bookmark {
            items[index].bookmark = refreshed
            items[index].status = .available
            items[index].openedAt = ports.clock()
            changed = true
        }
        if changed {
            ports.recents.save(items)
        }
    }

    func flushNotices() {
        noticeFlushScheduled = false
        let notices = pendingNotices
        pendingNotices.removeAll()
        for notice in notices.values {
            report(notice)
        }
    }

    func report(_ queued: IOSQueuedWorkspaceNotice) {
        guard let record = records[queued.workspaceID], !record.stopped else { return }
        guard record.generation == queued.generation, record.rootToken == queued.rootToken else { return }
        switch queued.notice {
        case .offlineRoot:
            publish(.unavailable(workspaceID: record.workspaceID, reason: .offline))
        case let .changed(path), let .deleted(path), let .availability(path, _):
            guard let location = reportLocation(path, record: record) else { return }
            publish(.resourceChanged(location))
        case let .moved(from, to):
            guard let location = reportLocation(from, record: record) else { return }
            publish(.resourceChanged(location))
            if let destination = reportLocation(to, record: record) {
                publish(.resourceChanged(destination))
            }
        }
    }

    func reportLocation(_ relativePath: String, record: IOSWorkspaceScopeRecord) -> IOSFileLocation? {
        guard record.scope == .directory else {
            guard relativePath == IOSWorkspacePathAuthority.lastComponent(record.rootURL.path(percentEncoded: false))
                || relativePath == record.displayName
            else {
                return nil
            }
            return location(
                record: record,
                relativePath: record.displayName,
                fileURL: record.rootURL,
                identity: record.providerIdentity
            )
        }
        guard WorkspaceRelativePath(spelling: relativePath) != nil else { return nil }
        let resolved = fileURL(record: record, relativePath: relativePath)
        guard IOSWorkspacePathAuthority.directoryContains(
            root: record.rootURL,
            file: resolved,
            relativePath: relativePath
        ) else {
            return nil
        }
        return location(record: record, relativePath: relativePath, fileURL: resolved, identity: nil)
    }
}

@MainActor
final class IOSWorkspaceObservation: IOSObservation {
    let token = UUID()
    var handler: (@MainActor (IOSWorkspaceEvent) -> Void)?

    init(handler: @escaping @MainActor (IOSWorkspaceEvent) -> Void) {
        self.handler = handler
    }

    func cancel() {
        handler = nil
    }
}

@MainActor
final class IOSRetainedAccessLease: IOSWorkspaceAccessLease {
    let grant: IOSWorkspaceGrant
    private(set) var isReleased = false
    private weak var service: IOSWorkspaceAccessService?

    init(grant: IOSWorkspaceGrant, service: IOSWorkspaceAccessService) {
        self.grant = grant
        self.service = service
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        service?.releaseConsumer(self)
    }

    /// The captured grant is still the service's live, unrevoked generation.
    func authorizesCapturedGeneration() -> Bool {
        guard !isReleased, let service else { return false }
        return service.authorizes(workspaceID: grant.workspaceID, generation: grant.accessGeneration)
    }

    var accessService: IOSWorkspaceAccessService? {
        service
    }
}
