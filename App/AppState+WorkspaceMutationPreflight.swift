import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func validateWorkspaceMutationAvailability(
        _ source: WorkspaceFileSystemLocation
    ) throws {
        try validateWorkspaceMutationRecoveryStoresLoaded(at: source.fileURL)
        guard !source.relativePath.isEmpty else {
            throw WorkspaceMutationError.workspaceRootIsImmutable
        }
        guard workspaceMutationNamespaceDepth == 0 else {
            throw WorkspaceMutationError.operationAlreadyInProgress
        }
        guard workspaceImageAssetInsertionCount == 0 else {
            throw WorkspaceMutationError.imageInsertionInProgress
        }
    }

    func workspaceMutationManagedSessions() -> [DocumentSession] {
        var sessions = [currentDocument]
        sessions.append(contentsOf: sessionCache.values)
        sessions.append(contentsOf: retiredEditorDocumentSessions.values.map(\.session))
        sessions.append(contentsOf: editorDocumentBindingSessions.values)
        sessions.append(contentsOf: editorBindingInstallations.values)
        sessions.append(contentsOf: workspaceMutationRetainedRecoverySessions())
        var seen: Set<ObjectIdentifier> = []
        return sessions.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    func workspaceManagedSessionProof(
        for session: DocumentSession,
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) -> WorkspaceManagedSessionProof? {
        let sessionIdentity = ObjectIdentifier(session)
        if let binding = anchoredSessionFileBindings[sessionIdentity],
           binding.location.rootAuthority == rootAuthority
        {
            return WorkspaceManagedSessionProof(
                location: binding.location,
                identity: binding.identity,
                sha256Digest: binding.sha256Digest
            )
        }
        if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[sessionIdentity] {
            let location: WorkspaceFileSystemLocation? = if proof.installedWorkspaceLocation?
                .rootAuthority == rootAuthority
            {
                proof.installedWorkspaceLocation
            } else if proof.location.rootAuthority == rootAuthority {
                proof.location
            } else {
                nil
            }
            if let location {
                return WorkspaceManagedSessionProof(
                    location: location,
                    identity: proof.identity,
                    sha256Digest: proof.sha256Digest
                )
            }
        }
        return nil
    }

    func workspaceSessionWithoutProof(
        _ session: DocumentSession,
        mayBeAffectedBy source: WorkspaceFileSystemLocation,
        sourceIsDirectory: Bool
    ) -> Bool {
        guard let stateURL = sessionStateURL(for: session),
              let relativePath = try? source.rootAuthority.relativePath(forFileURL: stateURL)
        else {
            return false
        }
        return exactRelativePath(
            relativePath,
            isAffectedBy: source.relativePath,
            sourceIsDirectory: sourceIsDirectory
        )
    }

    func validateWorkspaceRelocationDestinations(
        _ records: [WorkspaceSessionRelocationRecord],
        destination: WorkspaceFileSystemLocation
    ) throws {
        let relocatingSessionIdentities = Set(records.map { ObjectIdentifier($0.session) })
        try validateWorkspaceMutationDestinationOwnership(
            destination,
            excludingSessionIdentities: relocatingSessionIdentities,
            excludingSourceURLs: records.map(\.oldURL)
        )
        var destinationKeys = Set<[UInt8]>()
        for record in records {
            guard destinationKeys.insert(exactPathBytes(record.newURL)).inserted else {
                throw WorkspaceMutationError.sessionDestinationConflict(record.newURL)
            }
            for session in workspaceMutationManagedSessions()
                where !relocatingSessionIdentities.contains(ObjectIdentifier(session))
            {
                if let stateURL = sessionStateURL(for: session),
                   exactFileURLSpellingMatches(stateURL, record.newURL)
                {
                    throw WorkspaceMutationError.sessionDestinationConflict(record.newURL)
                }
            }
            if sessionPolicy.dirtyState(for: record.newURL) != nil {
                throw WorkspaceMutationError.sessionDestinationConflict(record.newURL)
            }
            try validateURLKeyDestination(record.newURL, records: records)
        }
    }

    /// Destination ownership is App-global, not a side effect of finding a source session.
    /// An unopened source therefore cannot publish into a missing spelling still retained by a
    /// cached, retired, detached, editor-bound, LRU, prompt, or recovery owner.
    func validateWorkspaceMutationDestinationOwnership(
        _ destination: WorkspaceFileSystemLocation,
        excludingSessionIdentities: Set<ObjectIdentifier> = [],
        excludingSourceURLs: [URL] = []
    ) throws {
        let parentIsCaseSensitive = try WorkspaceNoFollowItemInspector.parentIsCaseSensitive(
            of: destination
        )
        let destinationKey = workspaceSaveCopyAliasKey(
            destination.relativePath,
            parentIsCaseSensitive: parentIsCaseSensitive
        )

        for session in workspaceMutationManagedSessions()
            where !excludingSessionIdentities.contains(ObjectIdentifier(session))
        {
            guard let stateURL = sessionStateURL(for: session),
                  let relativePath = try? destination.rootAuthority.relativePath(
                      forFileURL: stateURL
                  )
            else {
                continue
            }
            if workspaceMutationDestination(
                destinationKey,
                owns: relativePath,
                parentIsCaseSensitive: parentIsCaseSensitive
            ) {
                throw WorkspaceMutationError.sessionDestinationConflict(destination.fileURL)
            }
        }

        for ownedURL in workspaceMutationOwnedStateURLs() {
            guard !excludingSourceURLs.contains(where: {
                exactFileURLSpellingMatches($0, ownedURL)
            }),
                let relativePath = try? destination.rootAuthority.relativePath(
                    forFileURL: ownedURL
                )
            else {
                continue
            }
            if workspaceMutationDestination(
                destinationKey,
                owns: relativePath,
                parentIsCaseSensitive: parentIsCaseSensitive
            ) {
                throw WorkspaceMutationError.sessionDestinationConflict(destination.fileURL)
            }
        }
    }

    func workspaceMutationDestination(
        _ destinationKey: String,
        owns candidateRelativePath: String,
        parentIsCaseSensitive: Bool
    ) -> Bool {
        let candidateKey = workspaceSaveCopyAliasKey(
            candidateRelativePath,
            parentIsCaseSensitive: parentIsCaseSensitive
        )
        return workspaceMutationRelativePathIsAffected(
            candidateKey,
            source: destinationKey,
            sourceIsDirectory: true
        ) || workspaceMutationRelativePathIsAffected(
            destinationKey,
            source: candidateKey,
            sourceIsDirectory: true
        )
    }

    func workspaceMutationOwnedStateURLs() -> [URL] {
        var urls = sessionPolicy.warmURLsInLeastRecentOrder
        urls.append(contentsOf: sessionCache.keys)
        urls.append(contentsOf: retiredEditorDocumentSessions.keys)
        urls.append(contentsOf: lastKnownDiskHashes.keys)
        urls.append(contentsOf: lastKnownDiskModificationDates.keys)
        urls.append(contentsOf: pendingExternalTexts.keys)
        urls.append(contentsOf: pendingExternalFileVersions.keys)
        urls.append(contentsOf: deferredExternalChangeResolutions.keys)
        urls.append(contentsOf: externalResolutionIntentCaptures.keys)
        urls.append(contentsOf: detachedSessionURLs)
        urls.append(contentsOf: indeterminateSessionWriteContexts.values.map(\.location.fileURL))
        urls.append(contentsOf: workspaceMutationTextRecoveryContexts.values.map(\.originalURL))
        urls.append(contentsOf: pendingWorkspaceMutationTextRecoveryRecords.map(\.originalURL))
        urls.append(contentsOf: pendingWorkspaceMutationOperationRecoveryRecords.flatMap(
            \.workspaceOwnedCandidateDisplayURLs
        ))
        urls.append(contentsOf: workspaceMutationOperationRecoveryRecords.values.flatMap(
            \.workspaceOwnedCandidateDisplayURLs
        ))
        urls.append(contentsOf: workspaceMutationRecoveries.values.flatMap {
            $0.retainedCandidateLocations.map(\.fileURL)
        })
        if let externalChangePrompt {
            urls.append(externalChangePrompt.fileURL)
        }
        if let missingFilePrompt {
            urls.append(missingFilePrompt.fileURL)
        }
        return urls
    }

    func validateURLKeyDestination(
        _ destination: URL,
        records: [WorkspaceSessionRelocationRecord]
    ) throws {
        let oldURLs = records.map(\.oldURL)
        let destinationIsRelocatingSource = oldURLs.contains {
            exactFileURLSpellingMatches($0, destination)
        }
        guard !destinationIsRelocatingSource else {
            throw WorkspaceMutationError.sessionDestinationConflict(destination)
        }
        let occupied = sessionCache.keys.contains { exactFileURLSpellingMatches($0, destination) }
            || retiredEditorDocumentSessions.keys.contains {
                exactFileURLSpellingMatches($0, destination)
            }
            || lastKnownDiskHashes.keys.contains { exactFileURLSpellingMatches($0, destination) }
            || lastKnownDiskModificationDates.keys.contains {
                exactFileURLSpellingMatches($0, destination)
            }
            || pendingExternalTexts.keys.contains { exactFileURLSpellingMatches($0, destination) }
            || pendingExternalFileVersions.keys.contains {
                exactFileURLSpellingMatches($0, destination)
            }
            || deferredExternalChangeResolutions.keys.contains {
                exactFileURLSpellingMatches($0, destination)
            }
            || externalResolutionIntentCaptures.keys.contains {
                exactFileURLSpellingMatches($0, destination)
            }
            || detachedSessionURLs.contains { exactFileURLSpellingMatches($0, destination) }
            || externalChangePrompt.map {
                exactFileURLSpellingMatches($0.fileURL, destination)
            } == true
            || missingFilePrompt.map {
                exactFileURLSpellingMatches($0.fileURL, destination)
            } == true
        guard !occupied else {
            throw WorkspaceMutationError.sessionDestinationConflict(destination)
        }
    }
}
