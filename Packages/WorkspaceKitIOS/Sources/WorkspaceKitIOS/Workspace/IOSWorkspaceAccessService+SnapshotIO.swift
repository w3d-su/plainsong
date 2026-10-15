import Foundation
import WorkspaceCore

extension IOSWorkspaceAccessService {
    func loadSnapshot(
        context: IOSDetachedAdmission,
        requestID: UUID
    ) async throws -> IOSWorkspaceSnapshot {
        if context.scope == .singleFile {
            let relative = WorkspaceRelativePath(spelling: context.displayName) == nil ? "file" : context.displayName
            let item = try await perform(context.ticket) {
                try await context.files.metadata(url: context.rootURL, relativePath: relative, root: context.rootURL)
            }
            return try await MainActor.run {
                let record = try accept(context.ticket)
                guard let entry = IOSWorkspaceTreeBuilder.singleFileEntry(record: record, item: item) else {
                    throw IOSWorkspaceFailure.invalidPath
                }
                return IOSWorkspaceSnapshot(
                    workspaceID: record.workspaceID,
                    accessGeneration: record.generation,
                    requestID: requestID,
                    entries: [entry]
                )
            }
        }
        let items = try await listTree(context: context)
        return try await MainActor.run {
            let record = try accept(context.ticket)
            return IOSWorkspaceTreeBuilder.makeSnapshot(
                record: record,
                items: items,
                requestID: requestID,
                includesHiddenEntries: context.includesHiddenEntries,
                includesAllFiles: context.includesAllFiles
            )
        }
    }

    func listTree(context: IOSDetachedAdmission) async throws -> [IOSWorkspaceFileItem] {
        var output: [IOSWorkspaceFileItem] = []
        var pending = [""]
        var seen: Set<[UInt8]> = [[]]
        while let parent = pending.popLast() {
            try Task.checkCancellation()
            let directoryURL = try directoryURL(root: context.rootURL, parent: parent)
            let children = try await perform(context.ticket) {
                try await context.files.list(url: directoryURL, relativePath: parent, root: context.rootURL)
            }
            for child in children where seen.insert(Array(child.relativePath.utf8)).inserted {
                output.append(child)
                if child.isDirectory, !child.isSymlink {
                    pending.append(child.relativePath)
                }
            }
        }
        return output
    }

    func notePersisted(_ leaf: IOSPersistedLeaf, operationID: UUID) async {
        await MainActor.run {
            persistedLeaves[operationID] = leaf
        }
    }

    func clearPersisted(_ operationID: UUID) async {
        await MainActor.run {
            persistedLeaves[operationID] = nil
        }
    }

    func takePersisted(_ operationID: UUID) async -> IOSPersistedLeaf? {
        await MainActor.run {
            persistedLeaves.removeValue(forKey: operationID)
        }
    }

    nonisolated func persistedLeaf(_ persisted: IOSFilePersistedButUnreadable, root: URL) -> IOSPersistedLeaf {
        IOSPersistedLeaf(
            url: persisted.url,
            relativePath: persisted.relativePath,
            byteCount: persisted.byteCount,
            providerIdentity: persisted.providerIdentity,
            root: root
        )
    }

    func throwUnpublishedOrClean(
        _ leaf: IOSPersistedLeaf,
        context: IOSDetachedAdmission,
        operationID: UUID,
        reason: IOSWorkspaceFailure
    ) async throws -> Never {
        let removed = await reclaim(leaf)
        await clearPersisted(operationID)
        await finishWork(context.ticket)
        if removed {
            throw reason
        }
        throw IOSUnpublishedLeaf(
            operationID: operationID,
            workspaceID: context.ticket.workspaceID,
            generation: context.ticket.generation,
            relativePath: leaf.relativePath,
            url: leaf.url,
            providerIdentity: leaf.providerIdentity,
            byteCount: leaf.byteCount,
            reason: reason
        )
    }

    func reclaim(_ leaf: IOSPersistedLeaf) async -> Bool {
        guard let identity = leaf.providerIdentity else { return false }
        do {
            try await ports.files.removeIfOwned(
                url: leaf.url,
                relativePath: leaf.relativePath,
                root: leaf.root,
                providerIdentity: identity
            )
            return true
        } catch let failure as IOSWorkspaceFailure where failure == .notFound {
            return true
        } catch {
            return false
        }
    }

    private func directoryURL(root: URL, parent: String) throws -> URL {
        if parent.isEmpty {
            return root
        }
        guard WorkspaceRelativePath(spelling: parent) != nil else {
            throw IOSWorkspaceFailure.invalidPath
        }
        return IOSWorkspacePathAuthority.fileURL(
            path: IOSWorkspacePathAuthority.joined(root: root, relativePath: parent)
        )
    }
}
