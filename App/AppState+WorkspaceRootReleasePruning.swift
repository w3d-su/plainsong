import Foundation
import MarkdownCore

@MainActor
extension AppState {
    /// Drops metadata for sessions this root released. Sessions outside the release set
    /// keep fences, bindings, proofs, quarantine, detached URLs, and external versions,
    /// including other roots and standalone warm sessions.
    func pruneMetadataAfterRootRelease(releasing releasedSessions: [DocumentSession]) {
        let releasedIdentities = Set(releasedSessions.map(ObjectIdentifier.init))
        var retainedSessions = registry.sessions(from: [
            .warmCache, .retired, .editorBindings, .editorInstallations,
            .mutationRecovery, .fileBackedWindowDocuments,
        ]).filter { !releasedIdentities.contains(ObjectIdentifier($0)) }
        retainedSessions.append(contentsOf: registry.sessions(from: [
            .retired, .mutationRecovery, .fileBackedWindowDocuments,
        ]))
        retainedSessions.append(contentsOf: registry.sessions(from: [
            .warmCache, .editorBindings, .editorInstallations, .mutationRecovery,
        ]).filter { session in
            indeterminateWorkspaceMutationSessions.contains(ObjectIdentifier(session))
        })
        var seen: Set<ObjectIdentifier> = []
        retainedSessions = retainedSessions.filter { seen.insert(ObjectIdentifier($0)).inserted }
        let retainedURLs = Set(retainedSessions.compactMap(sessionStateURL(for:)))
        let retainedSessionIdentities = Set(retainedSessions.map(ObjectIdentifier.init))
        pendingExternalTexts = pendingExternalTexts.filter { retainedURLs.contains($0.key) }
        pendingExternalFileVersions = pendingExternalFileVersions.filter {
            retainedURLs.contains($0.key)
        }
        deferredExternalChangeResolutions = deferredExternalChangeResolutions.filter {
            retainedURLs.contains($0.key)
        }
        externalResolutionIntentCaptures = externalResolutionIntentCaptures.filter {
            retainedURLs.contains($0.key)
        }
        lastKnownDiskHashes = lastKnownDiskHashes.filter { retainedURLs.contains($0.key) }
        lastKnownDiskModificationDates = lastKnownDiskModificationDates.filter {
            retainedURLs.contains($0.key)
        }
        detachedSessionURLs = Set(detachedSessionURLs.filter(retainedURLs.contains))
        anchoredSessionFileBindings = anchoredSessionFileBindings.filter {
            retainedSessionIdentities.contains($0.key)
        }
        unanchoredManagedSessionOwnershipProofs = unanchoredManagedSessionOwnershipProofs.filter {
            retainedSessionIdentities.contains($0.key)
        }
        editorImageAssetDocumentAuthorities = editorImageAssetDocumentAuthorities.filter {
            retainedSessionIdentities.contains($0.key)
        }
        indeterminateSessionWrites = indeterminateSessionWrites.filter {
            retainedSessionIdentities.contains($0.key)
        }
        indeterminateSessionWriteContexts = indeterminateSessionWriteContexts.filter {
            retainedSessionIdentities.contains($0.key)
        }
        indeterminateWorkspaceMutationSessions = Set(
            indeterminateWorkspaceMutationSessions.filter(retainedSessionIdentities.contains)
        )
    }
}
