import Foundation

public extension IOSWorkspaceAccessService {
    func recentItems() -> [IOSRecentWorkspaceItem] {
        ports.recents.load().map(\.item)
    }

    func removeRecent(recordID: UUID) {
        recentRestoreRequests[recordID] = nil
        var items = ports.recents.load()
        items.removeAll { $0.recordID == recordID }
        ports.recents.save(items)
    }

    /// The UI supplies only this opaque ID. Bookmark bytes and the captured scope
    /// stay inside this service; a display name never becomes a file URL.
    func restoreRecent(recordID: UUID) async throws -> IOSWorkspaceGrant {
        try Task.checkCancellation()
        guard let captured = ports.recents.load().first(where: { $0.recordID == recordID }) else {
            throw IOSWorkspaceFailure.notFound
        }
        guard captured.status == .available else { throw IOSWorkspaceFailure.permissionDenied }
        guard recentRestoreRequests[recordID] == nil else { throw IOSWorkspaceFailure.unavailable }
        let requestID = UUID()
        recentRestoreRequests[recordID] = requestID
        defer {
            if recentRestoreRequests[recordID] == requestID {
                recentRestoreRequests[recordID] = nil
            }
        }
        let grant = try await restoreRecordedGrant(captured)
        return try completeRecentRestore(grant, captured: captured, requestID: requestID)
    }

    private func restoreRecordedGrant(_ captured: IOSStoredRecentWorkspace) async throws -> IOSWorkspaceGrant {
        do {
            return try await restore(bookmark: captured.bookmark, scope: captured.scope)
        } catch {
            if let failure = error as? IOSWorkspaceFailure,
               [.permissionDenied, .notFound, .invalidPath, .outsideGrant].contains(failure)
            {
                var items = ports.recents.load()
                if let index = items.firstIndex(where: { $0.recordID == captured.recordID }) {
                    items[index].status = .needsReselection
                    ports.recents.save(items)
                }
            }
            throw error
        }
    }

    private func completeRecentRestore(
        _ grant: IOSWorkspaceGrant,
        captured: IOSStoredRecentWorkspace,
        requestID: UUID
    ) throws -> IOSWorkspaceGrant {
        let recordID = captured.recordID
        guard let record = records[grant.workspaceID], let rememberedID = record.recentRecordID else {
            _ = invalidate(grant.workspaceID)
            throw IOSWorkspaceFailure.grantChanged
        }
        let stillRequested = recentRestoreRequests[recordID] == requestID
        let cancelled = Task.isCancelled
        var items = ports.recents.load()
        let remembered = items.first { $0.recordID == rememberedID }
        items.removeAll { $0.recordID == rememberedID || $0.recordID == recordID }
        if stillRequested {
            // `remember` may deduplicate by provider identity. Preserve the row's
            // ID on success, or its captured metadata if cancellation drained.
            var retained = cancelled ? captured : (remembered ?? captured)
            retained.recordID = recordID
            items.insert(retained, at: 0)
        }
        if items.count > maximumRecentItems {
            items.removeLast(items.count - maximumRecentItems)
        }
        ports.recents.save(items)
        record.recentRecordID = stillRequested ? recordID : nil
        guard stillRequested, !cancelled else {
            _ = invalidate(grant.workspaceID)
            if cancelled {
                throw CancellationError()
            }
            throw IOSWorkspaceFailure.notFound
        }
        return grant
    }
}
