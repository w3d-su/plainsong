import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    struct WorkspaceManagedSessionProof {
        let location: WorkspaceFileSystemLocation
        let identity: WorkspaceFileSystemIdentity
        let sha256Digest: String
    }

    struct WorkspaceSessionRelocationRecord {
        let session: DocumentSession
        let newLocation: WorkspaceFileSystemLocation
        let oldURL: URL
        let newURL: URL
        let identity: WorkspaceFileSystemIdentity
        let sha256Digest: String
        let wasCached: Bool
        let retirement: RetiredEditorDocumentSession?
        let hadLRUEntry: Bool
        let knownDiskHash: String?
        let knownDiskModificationDate: Date?
        let pendingExternalText: String?
        let pendingExternalFileVersion: ObservedRetainedFileVersion?
        let deferredExternalResolution: DeferredExternalChangeResolution?
        let wasDetached: Bool
        let hadExternalDiskInspection: Bool
    }

    struct WorkspaceRelocationPlan {
        let source: WorkspaceFileSystemLocation
        let destination: WorkspaceFileSystemLocation
        let expectation: WorkspaceItemMutationExpectation
        let records: [WorkspaceSessionRelocationRecord]
        let relocatedSessionPolicy: WorkspaceSessionLRUPolicy
    }

    struct PreparedWorkspaceRelocationCommit {
        let imageAuthorities: [ObjectIdentifier: PreparedEditorImageAssetDocumentAuthority]
    }

    struct WorkspaceTrashSessionRecord {
        let session: DocumentSession
        let oldLocation: WorkspaceFileSystemLocation
        let oldURL: URL
        let identity: WorkspaceFileSystemIdentity
        let sha256Digest: String
        let initialVersion: Int
        let deferredExternalResolution: DeferredExternalChangeResolution?
        let hadExternalDiskInspection: Bool
    }

    struct WorkspaceSessionRelocationOwnership {
        let wasCached: Bool
        let retirement: RetiredEditorDocumentSession?
    }

    struct WorkspaceRelocationURLState {
        let knownDiskHash: String?
        let knownDiskModificationDate: Date?
        let pendingExternalText: String?
        let pendingExternalFileVersion: ObservedRetainedFileVersion?
        let deferredExternalResolution: DeferredExternalChangeResolution?
        let wasDetached: Bool
    }

    func workspaceRenameDestination(
        source: WorkspaceFileSystemLocation,
        newName: String
    ) throws -> WorkspaceFileSystemLocation {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              newName != ".",
              newName != "..",
              !newName.utf8.contains(0),
              !newName.utf8.contains(0x2F)
        else {
            throw WorkspaceMutationError.invalidName
        }
        var components = exactRelativePathComponents(source.relativePath)
        guard !components.isEmpty else {
            throw WorkspaceMutationError.workspaceRootIsImmutable
        }
        components[components.count - 1] = newName
        return try source.rootAuthority.location(relativePath: components.joined(separator: "/"))
    }

    func workspaceMoveDestination(
        source: WorkspaceFileSystemLocation,
        directoryRelativePath: String
    ) throws -> WorkspaceFileSystemLocation {
        guard let leaf = exactRelativePathComponents(source.relativePath).last else {
            throw WorkspaceMutationError.workspaceRootIsImmutable
        }
        let directoryComponents = exactRelativePathComponents(directoryRelativePath)
        let relativePath = (directoryComponents + [leaf]).joined(separator: "/")
        return try source.rootAuthority.location(relativePath: relativePath)
    }

    func prepareWorkspaceRelocationPlan(
        source: WorkspaceFileSystemLocation,
        destination: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation
    ) throws -> WorkspaceRelocationPlan {
        guard workspaceSearchRootAuthority == source.rootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration
        else {
            throw WorkspaceMutationError.staleWorkspaceSnapshot(source.fileURL)
        }
        guard destination.rootAuthority == source.rootAuthority else {
            throw WorkspaceMutationError.itemOutsideWorkspace(destination.fileURL)
        }
        try validateWorkspaceMutationAvailability(source)

        let records = try workspaceSessionRelocationRecords(
            source: source,
            destination: destination,
            expectation: expectation
        )
        try validateWorkspaceRelocationDestinations(
            records,
            destination: destination
        )

        var relocatedPolicy = sessionPolicy
        for record in records where record.hadLRUEntry {
            do {
                try relocatedPolicy.relocate(from: record.oldURL, to: record.newURL)
            } catch {
                throw WorkspaceMutationError.sessionDestinationConflict(record.newURL)
            }
        }
        return WorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: expectation,
            records: records,
            relocatedSessionPolicy: relocatedPolicy
        )
    }

    func prepareWorkspaceTrashRecords(
        source: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation
    ) throws -> [WorkspaceTrashSessionRecord] {
        guard workspaceSearchRootAuthority == source.rootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration
        else {
            throw WorkspaceMutationError.staleWorkspaceSnapshot(source.fileURL)
        }
        try validateWorkspaceMutationAvailability(source)
        guard expectation.kind != .symbolicLink else { return [] }

        let sourceIsDirectory = expectation.kind == .directory
        let records: [WorkspaceTrashSessionRecord] = try
            workspaceMutationManagedSessions().compactMap { session in
                guard let proof = try affectedWorkspaceManagedSessionProof(
                    for: session,
                    source: source,
                    expectation: expectation,
                    sourceIsDirectory: sourceIsDirectory
                ) else {
                    return nil
                }
                let oldURL = try validatedWorkspaceMutationOldURL(
                    for: session,
                    proof: proof
                )
                let sessionIdentity = ObjectIdentifier(session)
                return WorkspaceTrashSessionRecord(
                    session: session,
                    oldLocation: proof.location,
                    oldURL: oldURL,
                    identity: proof.identity,
                    sha256Digest: proof.sha256Digest,
                    initialVersion: session.version,
                    deferredExternalResolution: exactURLValue(
                        in: deferredExternalChangeResolutions,
                        at: oldURL
                    ),
                    hadExternalDiskInspection: externalDiskInspectionTasks[sessionIdentity] != nil
                )
            }
        return records.sorted {
            exactPathBytes($0.oldURL).lexicographicallyPrecedes(exactPathBytes($1.oldURL))
        }
    }

    func workspaceSessionRelocationRecords(
        source: WorkspaceFileSystemLocation,
        destination: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation
    ) throws -> [WorkspaceSessionRelocationRecord] {
        guard expectation.kind != .symbolicLink else { return [] }
        let sourceIsDirectory = expectation.kind == .directory
        let records: [WorkspaceSessionRelocationRecord] = try
            workspaceMutationManagedSessions().compactMap { session in
                try workspaceSessionRelocationRecord(
                    for: session,
                    source: source,
                    destination: destination,
                    expectation: expectation,
                    sourceIsDirectory: sourceIsDirectory
                )
            }
        return records.sorted {
            exactPathBytes($0.oldURL).lexicographicallyPrecedes(exactPathBytes($1.oldURL))
        }
    }

    func workspaceSessionRelocationRecord(
        for session: DocumentSession,
        source: WorkspaceFileSystemLocation,
        destination: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        sourceIsDirectory: Bool
    ) throws -> WorkspaceSessionRelocationRecord? {
        guard let proof = try affectedWorkspaceManagedSessionProof(
            for: session,
            source: source,
            expectation: expectation,
            sourceIsDirectory: sourceIsDirectory
        ) else {
            return nil
        }
        let oldURL = try validatedWorkspaceMutationOldURL(for: session, proof: proof)
        let newRelativePath = relocatedRelativePath(
            proof.location.relativePath,
            from: source.relativePath,
            to: destination.relativePath,
            sourceIsDirectory: sourceIsDirectory
        )
        let newLocation = try source.rootAuthority.location(relativePath: newRelativePath)
        let ownership = try workspaceSessionRelocationOwnership(
            for: session,
            oldURL: oldURL
        )
        let state = workspaceRelocationURLState(at: oldURL)
        guard state.pendingExternalFileVersion?.identity == nil ||
            state.pendingExternalFileVersion?.identity == proof.identity
        else {
            throw WorkspaceMutationError.staleWorkspaceSnapshot(oldURL)
        }
        return WorkspaceSessionRelocationRecord(
            session: session,
            newLocation: newLocation,
            oldURL: oldURL,
            newURL: newLocation.fileURL,
            identity: proof.identity,
            sha256Digest: proof.sha256Digest,
            wasCached: ownership.wasCached,
            retirement: ownership.retirement,
            hadLRUEntry: sessionPolicy.dirtyState(for: oldURL) != nil,
            knownDiskHash: state.knownDiskHash,
            knownDiskModificationDate: state.knownDiskModificationDate,
            pendingExternalText: state.pendingExternalText,
            pendingExternalFileVersion: state.pendingExternalFileVersion,
            deferredExternalResolution: state.deferredExternalResolution,
            wasDetached: state.wasDetached,
            hadExternalDiskInspection: externalDiskInspectionTasks[ObjectIdentifier(session)] != nil
        )
    }

    func affectedWorkspaceManagedSessionProof(
        for session: DocumentSession,
        source: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation,
        sourceIsDirectory: Bool
    ) throws -> WorkspaceManagedSessionProof? {
        guard let proof = workspaceManagedSessionProof(
            for: session,
            rootAuthority: source.rootAuthority
        ) else {
            if workspaceSessionWithoutProof(
                session,
                mayBeAffectedBy: source,
                sourceIsDirectory: sourceIsDirectory
            ) {
                throw WorkspaceMutationError.unprovenSessionAuthority(
                    sessionStateURL(for: session) ?? source.fileURL
                )
            }
            return nil
        }
        guard exactRelativePath(
            proof.location.relativePath,
            isAffectedBy: source.relativePath,
            sourceIsDirectory: sourceIsDirectory
        ) else {
            return nil
        }
        if !sourceIsDirectory,
           proof.identity != expectation.identity
        {
            throw WorkspaceMutationError.staleWorkspaceSnapshot(source.fileURL)
        }
        return proof
    }

    func validatedWorkspaceMutationOldURL(
        for session: DocumentSession,
        proof: WorkspaceManagedSessionProof
    ) throws -> URL {
        let sessionIdentity = ObjectIdentifier(session)
        guard indeterminateSessionWrites[sessionIdentity] == nil,
              indeterminateSessionWriteContexts[sessionIdentity] == nil,
              !indeterminateWorkspaceMutationSessions.contains(sessionIdentity)
        else {
            throw WorkspaceMutationError.indeterminateSession(
                sessionStateURL(for: session) ?? proof.location.fileURL
            )
        }
        guard !hasPendingEditorSource(for: session) else {
            throw AppStateError.pendingEditorSource(
                sessionStateURL(for: session) ?? proof.location.fileURL
            )
        }
        guard let oldURL = sessionStateURL(for: session) else {
            throw WorkspaceMutationError.unprovenSessionAuthority(proof.location.fileURL)
        }
        guard !detachedSessionURLs.contains(where: {
            exactFileURLSpellingMatches($0, oldURL)
        }) else {
            throw AppStateError.missingFile(oldURL)
        }
        return oldURL
    }

    func workspaceSessionRelocationOwnership(
        for session: DocumentSession,
        oldURL: URL
    ) throws -> WorkspaceSessionRelocationOwnership {
        let cacheKeys = sessionCache.compactMap { key, owner in owner === session ? key : nil }
        guard cacheKeys.count <= 1,
              cacheKeys.allSatisfy({ exactFileURLSpellingMatches($0, oldURL) })
        else {
            throw AppStateError.duplicateSessionOwnership(oldURL)
        }
        let retirements = retiredEditorDocumentSessions.compactMap { key, retirement in
            retirement.session === session ? (key, retirement) : nil
        }
        guard retirements.count <= 1,
              retirements.allSatisfy({ exactFileURLSpellingMatches($0.0, oldURL) })
        else {
            throw AppStateError.duplicateSessionOwnership(oldURL)
        }
        return WorkspaceSessionRelocationOwnership(
            wasCached: cacheKeys.count == 1,
            retirement: retirements.first?.1
        )
    }

    func workspaceRelocationURLState(at oldURL: URL) -> WorkspaceRelocationURLState {
        WorkspaceRelocationURLState(
            knownDiskHash: exactURLValue(in: lastKnownDiskHashes, at: oldURL),
            knownDiskModificationDate: exactURLValue(
                in: lastKnownDiskModificationDates,
                at: oldURL
            ),
            pendingExternalText: exactURLValue(in: pendingExternalTexts, at: oldURL),
            pendingExternalFileVersion: exactURLValue(
                in: pendingExternalFileVersions,
                at: oldURL
            ),
            deferredExternalResolution: exactURLValue(
                in: deferredExternalChangeResolutions,
                at: oldURL
            ),
            wasDetached: detachedSessionURLs.contains(where: {
                exactFileURLSpellingMatches($0, oldURL)
            })
        )
    }
}
