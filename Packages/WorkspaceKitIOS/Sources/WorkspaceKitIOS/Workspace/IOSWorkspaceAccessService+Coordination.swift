import Foundation
import MarkdownCore
import WorkspaceCore

extension IOSWorkspaceAccessService: IOSCoordinatedFileAccess {
    public nonisolated func read(
        _ location: IOSFileLocation,
        lease: any IOSWorkspaceAccessLease,
        operationID: UUID,
        maximumByteCount: Int
    ) async throws -> IOSCoordinatedRead {
        try Task.checkCancellation()
        let context = try await begin(
            location: location,
            lease: lease,
            operationID: operationID,
            requestID: nil
        )
        do {
            let item = try await context.files.metadata(url: location.fileURL, relativePath: location.relativePath)
            if item.isSymlink {
                throw IOSWorkspaceFailure.outsideGrant
            }
            if let size = item.fileSize, size > maximumByteCount {
                throw IOSWorkspaceFailure.tooLarge
            }
            var data = Data()
            do {
                data = try await context.files.readFile(
                    url: location.fileURL,
                    relativePath: location.relativePath,
                    maximumByteCount: maximumByteCount
                )
            } catch {
                // LANE06_GUARD_EMPTY_FAILURE
                throw error
            }
            if data.count > maximumByteCount {
                throw IOSWorkspaceFailure.tooLarge
            }
            _ = try await acceptWork(context.ticket)
            await finishWork(context.ticket)
            return IOSCoordinatedRead(operationID: operationID, location: location, data: data)
        } catch {
            await finishWork(context.ticket)
            try rethrowWorkspace(error)
        }
    }

    public nonisolated func createNewLeaf(
        at location: IOSFileLocation,
        data: Data,
        lease: any IOSWorkspaceAccessLease,
        operationID: UUID
    ) async throws -> IOSCreatedLeaf {
        try Task.checkCancellation()
        let context = try await begin(
            location: location,
            lease: lease,
            operationID: operationID,
            requestID: nil
        )
        do {
            let created = try await context.files.createFile(
                url: location.fileURL,
                relativePath: location.relativePath,
                data: data
            )
            let accepted = try await MainActor.run { () throws -> (IOSWorkspaceIdentity, UInt64) in
                let record = try accept(context.ticket)
                return (record.workspaceID, record.generation)
            }
            await finishWork(context.ticket)
            let identity = created.providerIdentity ?? IOSWorkspaceOwnedIdentity.bytes(operationID)
            let createdLocation = IOSFileLocation(
                workspaceID: accepted.0,
                accessGeneration: accepted.1,
                relativePath: location.relativePath,
                fileURL: created.url,
                resourceID: created.providerIdentity.map { IOSWorkspaceResourceIdentity(rawValue: $0) }
            )
            return IOSCreatedLeaf(
                operationID: operationID,
                location: createdLocation,
                resourceID: IOSWorkspaceResourceIdentity(rawValue: identity)
            )
        } catch {
            await finishWork(context.ticket)
            try rethrowWorkspace(error)
        }
    }

    public nonisolated func directorySnapshot(
        for grant: IOSWorkspaceGrant,
        lease: any IOSWorkspaceAccessLease,
        requestID: UUID
    ) async throws -> IOSWorkspaceSnapshot {
        try Task.checkCancellation()
        let context = try await beginSnapshot(grant: grant, lease: lease, requestID: requestID)
        do {
            let snapshot = try await loadSnapshot(context: context, requestID: requestID)
            try Task.checkCancellation()
            try await publishIfCurrent(snapshot, ticket: context.ticket)
            await finishWork(context.ticket)
            return snapshot
        } catch {
            await finishWork(context.ticket)
            if workspaceFailure(error) == .offline {
                await publishOffline(grant.workspaceID)
            }
            try rethrowWorkspace(error)
        }
    }

    public nonisolated func events(
        for grant: IOSWorkspaceGrant,
        lease: any IOSWorkspaceAccessLease
    ) async -> AsyncStream<IOSWorkspaceEvent> {
        await MainActor.run {
            makeEventStream(grant: grant, lease: lease)
        }
    }
}

struct IOSDetachedAdmission: Sendable {
    var ticket: IOSOperationTicket
    var files: any IOSWorkspaceFilePort
    var includesHiddenEntries: Bool
    var includesAllFiles: Bool
    var scope: IOSWorkspaceScope
    var rootURL: URL
    var displayName: String
}

func rethrowWorkspace(_ error: Error) throws -> Never {
    if error is CancellationError {
        throw error
    }
    throw (error as? IOSWorkspaceFailure) ?? IOSWorkspaceFailureMapping.map(error)
}

func workspaceFailure(_ error: Error) -> IOSWorkspaceFailure? {
    if error is CancellationError {
        return nil
    }
    return (error as? IOSWorkspaceFailure) ?? IOSWorkspaceFailureMapping.map(error)
}

enum IOSWorkspaceOwnedIdentity {
    static func bytes(_ operationID: UUID) -> Data {
        var data = Data([0x06])
        withUnsafeBytes(of: operationID.uuid) { data.append(contentsOf: $0) }
        return data
    }
}

private extension IOSWorkspaceAccessService {
    func begin(
        location: IOSFileLocation,
        lease: any IOSWorkspaceAccessLease,
        operationID: UUID,
        requestID: UUID?
    ) async throws -> IOSDetachedAdmission {
        let ticket = try admit(
            location: location,
            lease: lease,
            operationID: operationID,
            requestID: requestID
        )
        return admission(ticket: ticket, grant: lease.grant)
    }

    func beginSnapshot(
        grant: IOSWorkspaceGrant,
        lease: any IOSWorkspaceAccessLease,
        requestID: UUID
    ) async throws -> IOSDetachedAdmission {
        guard lease.grant.workspaceID == grant.workspaceID,
              lease.grant.accessGeneration == grant.accessGeneration,
              IOSWorkspacePathAuthority.sameFile(lease.grant.rootURL, grant.rootURL)
        else {
            throw IOSWorkspaceFailure.grantChanged
        }
        let ticket: IOSOperationTicket
        if grant.scope == .directory {
            ticket = try admitDirectory(grant: grant, lease: lease, requestID: requestID)
        } else {
            let relative = records[grant.workspaceID]?.displayName ?? "file"
            let spelling = WorkspaceRelativePath(spelling: relative) == nil ? "file" : relative
            let location = IOSFileLocation(
                workspaceID: grant.workspaceID,
                accessGeneration: grant.accessGeneration,
                relativePath: spelling,
                fileURL: grant.rootURL,
                resourceID: nil
            )
            ticket = try admit(location: location, lease: lease, operationID: requestID, requestID: requestID)
        }
        return admission(ticket: ticket, grant: grant)
    }

    func admission(ticket: IOSOperationTicket, grant: IOSWorkspaceGrant) -> IOSDetachedAdmission {
        IOSDetachedAdmission(
            ticket: ticket,
            files: ports.files,
            includesHiddenEntries: includesHiddenEntries,
            includesAllFiles: includesAllFiles,
            scope: grant.scope,
            rootURL: grant.rootURL,
            displayName: records[grant.workspaceID]?.displayName ?? ""
        )
    }

    func admitDirectory(
        grant: IOSWorkspaceGrant,
        lease: any IOSWorkspaceAccessLease,
        requestID: UUID
    ) throws -> IOSOperationTicket {
        let scopeRecord = try record(for: lease)
        guard scopeRecord.workspaceID == grant.workspaceID else { throw IOSWorkspaceFailure.outsideGrant }
        guard scopeRecord.generation == grant.accessGeneration else { throw IOSWorkspaceFailure.grantChanged }
        guard scopeRecord.scope == .directory else { throw IOSWorkspaceFailure.requiresDirectoryGrant }
        scopeRecord.latestRequestID = requestID
        scopeRecord.addOperation()
        return IOSOperationTicket(
            workspaceID: scopeRecord.workspaceID,
            generation: scopeRecord.generation,
            rootToken: scopeRecord.rootToken,
            operationID: requestID,
            requestID: requestID
        )
    }

    func acceptWork(_ ticket: IOSOperationTicket) async throws -> IOSWorkspaceScopeRecord {
        try accept(ticket)
    }

    func finishWork(_ ticket: IOSOperationTicket) async {
        finish(ticket)
    }

    func loadSnapshot(
        context: IOSDetachedAdmission,
        requestID: UUID
    ) async throws -> IOSWorkspaceSnapshot {
        if context.scope == .singleFile {
            let relative = WorkspaceRelativePath(spelling: context.displayName) == nil ? "file" : context.displayName
            let item = try await context.files.metadata(url: context.rootURL, relativePath: relative)
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
        while let parent = pending.popLast() {
            try Task.checkCancellation()
            let children = try await context.files.list(url: context.rootURL, relativePath: parent)
            for child in children {
                output.append(child)
                if child.isDirectory, !child.isSymlink {
                    pending.append(child.relativePath)
                }
            }
        }
        return output
    }

    func publishIfCurrent(_ snapshot: IOSWorkspaceSnapshot, ticket: IOSOperationTicket) async throws {
        let record = try accept(ticket)
        guard snapshot.workspaceID == record.workspaceID,
              snapshot.accessGeneration == record.generation,
              snapshot.requestID == ticket.requestID
        else {
            throw IOSWorkspaceFailure.grantChanged
        }
        try publishSnapshot(snapshot, record: record)
    }

    func publishOffline(_ workspaceID: IOSWorkspaceIdentity) async {
        guard records[workspaceID] != nil else { return }
        publish(.unavailable(workspaceID: workspaceID, reason: .offline))
    }

    func makeEventStream(
        grant: IOSWorkspaceGrant,
        lease: any IOSWorkspaceAccessLease
    ) -> AsyncStream<IOSWorkspaceEvent> {
        AsyncStream { continuation in
            guard (try? record(for: lease)) != nil else {
                continuation.finish()
                return
            }
            let observation = IOSWorkspaceObservation { event in
                guard self.eventMatches(event, grant: grant) else { return }
                continuation.yield(event)
            }
            observations[observation.token] = observation
            continuation.onTermination = { _ in
                Task { @MainActor in
                    observation.cancel()
                    self.observations[observation.token] = nil
                }
            }
        }
    }

    func eventMatches(_ event: IOSWorkspaceEvent, grant: IOSWorkspaceGrant) -> Bool {
        switch event {
        case let .snapshotChanged(snapshot):
            snapshot.workspaceID == grant.workspaceID && snapshot.accessGeneration == grant.accessGeneration
        case let .invalidated(workspaceID, _):
            workspaceID == grant.workspaceID
        case let .resourceChanged(location):
            location.workspaceID == grant.workspaceID && location.accessGeneration == grant.accessGeneration
        case let .unavailable(workspaceID, _):
            workspaceID == grant.workspaceID
        }
    }
}
