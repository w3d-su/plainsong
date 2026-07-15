import Foundation
import MarkdownCore
import WorkspaceKit

struct UnanchoredManagedSessionFileProof: Equatable {
    let location: WorkspaceFileSystemLocation
    let identity: WorkspaceFileSystemIdentity
    let sha256Digest: String
    let installedWorkspaceLocation: WorkspaceFileSystemLocation?

    var retainedLocations: [WorkspaceFileSystemLocation] {
        if let installedWorkspaceLocation, installedWorkspaceLocation != location {
            return [location, installedWorkspaceLocation]
        }
        return [location]
    }
}

enum UnanchoredManagedSessionOwnershipProof: Equatable {
    case proven(UnanchoredManagedSessionFileProof)
    case unavailable(fileURL: URL?)
}

/// One coherent descriptor-bound disk version observed through a session's retained authority.
/// The text, identity, and digest are inseparable: Reload/Keep Mine must never restore one
/// observation while adopting the proof of another later read.
struct ObservedRetainedFileVersion: Equatable {
    let location: WorkspaceFileSystemLocation
    let file: MarkdownFile
    let identity: WorkspaceFileSystemIdentity
    let sha256Digest: String
    let preparedImageAssetAuthority: PreparedEditorImageAssetDocumentAuthority?

    init(
        location: WorkspaceFileSystemLocation,
        result: MarkdownFileReadResult,
        preparedImageAssetAuthority: PreparedEditorImageAssetDocumentAuthority? = nil
    ) {
        self.location = location
        file = result.file
        identity = result.metadata.identity
        sha256Digest = result.sha256Digest
        self.preparedImageAssetAuthority = preparedImageAssetAuthority
    }

    init(
        location: WorkspaceFileSystemLocation,
        file: MarkdownFile,
        identity: WorkspaceFileSystemIdentity,
        sha256Digest: String,
        preparedImageAssetAuthority: PreparedEditorImageAssetDocumentAuthority? = nil
    ) {
        self.location = location
        self.file = file
        self.identity = identity
        self.sha256Digest = sha256Digest
        self.preparedImageAssetAuthority = preparedImageAssetAuthority
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.location == rhs.location
            && ExactSourceText.matches(lhs.file.text, rhs.file.text)
            && lhs.file.fileKind == rhs.file.fileKind
            && lhs.identity == rhs.identity
            && lhs.sha256Digest == rhs.sha256Digest
            && preparedAuthorityMatches(
                lhs.preparedImageAssetAuthority,
                rhs.preparedImageAssetAuthority
            )
    }

    private static func preparedAuthorityMatches(
        _ lhs: PreparedEditorImageAssetDocumentAuthority?,
        _ rhs: PreparedEditorImageAssetDocumentAuthority?
    ) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            lhs.location == rhs.location && lhs.identity == rhs.identity
        case (nil, nil):
            true
        default:
            false
        }
    }
}

@MainActor
extension AppState {
    /// Captures physical ownership once, when an unanchored session first becomes App-managed.
    /// Later Save Copy arbitration consumes only this retained proof and never re-inspects the
    /// session's mutable display URL.
    func retainUnanchoredManagedSessionOwnership(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        if anchoredSessionFileBindings[sessionIdentity] != nil {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
            return
        }
        guard indeterminateSessionWriteContexts[sessionIdentity] == nil else {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
            discardEditorImageAssetDocumentAuthority(for: session)
            return
        }
        // This runs only at explicit session lifecycle boundaries. SwiftUI body evaluation
        // consumes retained proof/cache state and never calls this filesystem path.
        if case .proven? = unanchoredManagedSessionOwnershipProofs[sessionIdentity] { return }
        guard unanchoredManagedSessionOwnershipProofs[sessionIdentity] == nil else { return }
        guard let fileURL = session.fileURL else {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .unavailable(fileURL: nil)
            discardEditorImageAssetDocumentAuthority(for: session)
            return
        }

        do {
            let location = try WorkspaceFileSystemLocation(fileURL: fileURL)
            let preparedRead = try prepareEditorImageAssetDocumentRead(
                fileStore: fileStore,
                at: location
            )
            let loaded = preparedRead.result
            let installedLocation = installedWorkspaceLocation(
                for: location.fileURL,
                identity: loaded.metadata.identity
            )
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(
                UnanchoredManagedSessionFileProof(
                    location: location,
                    identity: loaded.metadata.identity,
                    sha256Digest: loaded.sha256Digest,
                    installedWorkspaceLocation: installedLocation
                )
            )
            if let installedLocation {
                installEditorImageAssetDocumentAuthority(
                    for: session,
                    location: installedLocation,
                    identity: loaded.metadata.identity,
                    preparedAuthority: preparedRead.preparedAuthority,
                    allowsBootstrapWithoutRetainedLineage: true
                )
            } else {
                discardEditorImageAssetDocumentAuthority(for: session)
            }
        } catch {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .unavailable(fileURL: fileURL)
            discardEditorImageAssetDocumentAuthority(for: session)
        }
    }

    func retainUnanchoredManagedSessionOwnership(
        for session: DocumentSession,
        location: WorkspaceFileSystemLocation,
        identity: WorkspaceFileSystemIdentity,
        sha256Digest: String,
        preparedImageAssetAuthority: PreparedEditorImageAssetDocumentAuthority? = nil
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        if anchoredSessionFileBindings[sessionIdentity] != nil {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
            return
        }
        guard indeterminateSessionWriteContexts[sessionIdentity] == nil else {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
            discardEditorImageAssetDocumentAuthority(for: session)
            return
        }
        if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[sessionIdentity] {
            retainInstalledWorkspaceMembershipIfAvailable(
                for: session,
                proof: proof
            )
            return
        }
        guard unanchoredManagedSessionOwnershipProofs[sessionIdentity] == nil else { return }
        let installedLocation = installedWorkspaceLocation(
            for: location.fileURL,
            identity: identity
        )
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(
            UnanchoredManagedSessionFileProof(
                location: location,
                identity: identity,
                sha256Digest: sha256Digest,
                installedWorkspaceLocation: installedLocation
            )
        )
        if let installedLocation {
            installEditorImageAssetDocumentAuthority(
                for: session,
                location: installedLocation,
                identity: identity,
                preparedAuthority: preparedImageAssetAuthority,
                allowsBootstrapWithoutRetainedLineage: true
            )
        } else {
            discardEditorImageAssetDocumentAuthority(for: session)
        }
    }

    func exactFileURLSpellingMatches(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.isFileURL, rhs.isFileURL else { return false }
        return lhs.path(percentEncoded: false).utf8.elementsEqual(
            rhs.path(percentEncoded: false).utf8
        )
    }

    /// Loads the session's exact retained location once, returning the text and write proof
    /// sampled from the same descriptor. This intentionally has no mutable-URL fallback.
    func observeRetainedFileVersion(for session: DocumentSession) throws -> ObservedRetainedFileVersion {
        let sessionIdentity = ObjectIdentifier(session)
        let location: WorkspaceFileSystemLocation
        // An indeterminate write temporarily owns a destination that can differ from the
        // session's prior binding. Its previous proof stays retained until explicit resolution,
        // but Reload/Keep Mine must observe the quarantined destination, not that old source.
        if indeterminateSessionWrites[sessionIdentity] != nil,
           let context = indeterminateSessionWriteContexts[sessionIdentity]
        {
            location = context.location
        } else if let binding = anchoredSessionFileBinding(for: session) {
            location = binding.location
        } else if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[sessionIdentity] {
            location = proof.location
        } else if let context = indeterminateSessionWriteContexts[sessionIdentity] {
            location = context.location
        } else {
            throw AppStateError.invalidSessionIdentity(sessionStateURL(for: session) ?? URL(fileURLWithPath: "/"))
        }
        let preparedRead = try prepareEditorImageAssetDocumentRead(
            fileStore: fileStore,
            at: location
        )
        return ObservedRetainedFileVersion(
            location: location,
            result: preparedRead.result,
            preparedImageAssetAuthority: preparedRead.preparedAuthority
        )
    }

    func observedRetainedFileVersionDiffers(
        _ observation: ObservedRetainedFileVersion,
        for session: DocumentSession
    ) -> Bool {
        let sessionIdentity = ObjectIdentifier(session)
        if let binding = anchoredSessionFileBindings[sessionIdentity] {
            return binding.location != observation.location
                || binding.identity != observation.identity
                || binding.sha256Digest != observation.sha256Digest
        }
        if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[sessionIdentity] {
            return proof.location != observation.location
                || proof.identity != observation.identity
                || proof.sha256Digest != observation.sha256Digest
        }
        return true
    }

    /// Decides whether a coherent observation is acceptable before any caller adopts a new
    /// anchored binding or unanchored identity/SHA proof. FNV and mtime remain bookkeeping only;
    /// they cannot make a changed disk version writable. A detached session still requires an
    /// explicit Reload/Keep Mine even when a restored leaf has the same identity and bytes: the
    /// missing-file transition intentionally invalidated its saved-text baseline and save fence.
    @discardableResult
    func reconcileObservedRetainedFileVersion(
        _ observation: ObservedRetainedFileVersion,
        for session: DocumentSession,
        canonicalURL: URL
    ) -> Bool {
        let sessionIdentity = ObjectIdentifier(session)
        let hasPendingConflict = pendingExternalTexts[canonicalURL] != nil
            || pendingExternalFileVersions[canonicalURL] != nil
        let isDetached = detachedSessionURLs.contains(canonicalURL)
        let changed = observedRetainedFileVersionDiffers(observation, for: session)
        let hasPendingEditorSource = hasPendingEditorSource(for: session)
        guard !hasPendingConflict,
              !isDetached,
              indeterminateSessionWrites[sessionIdentity] == nil,
              !changed || (!session.isDirty && !hasPendingEditorSource)
        else {
            recordExternalChangeConflict(
                observation,
                for: session,
                canonicalURL: canonicalURL
            )
            return false
        }

        if changed {
            session.reset(
                text: observation.file.text,
                url: canonicalURL,
                fileKind: observation.file.fileKind,
                isDirty: false
            )
            detachedSessionURLs.remove(canonicalURL)
            if session === currentDocument {
                missingFilePrompt = nil
            }
        }
        recordKnownSessionDiskText(
            observation.file.text,
            for: session,
            canonicalURL: canonicalURL
        )
        return true
    }

    func recordExternalChangeConflict(
        _ observation: ObservedRetainedFileVersion,
        for session: DocumentSession,
        canonicalURL: URL
    ) {
        pendingExternalTexts[canonicalURL] = observation.file.text
        pendingExternalFileVersions[canonicalURL] = observation
        cancelAutosave(for: session)
        if session === currentDocument {
            missingFilePrompt = nil
            externalChangePrompt = ExternalChangePrompt(fileURL: canonicalURL)
        }
    }

    func clearExternalChangeConflict(at canonicalURL: URL) {
        pendingExternalTexts[canonicalURL] = nil
        pendingExternalFileVersions[canonicalURL] = nil
    }

    /// Adopts an observation only after arbitration or an explicit Reload/Keep Mine decision.
    /// For unanchored sessions, changing identity intentionally drops stale installed-workspace
    /// membership rather than re-inspecting a mutable path to reconstruct it.
    @discardableResult
    func adoptObservedRetainedFileVersion(
        _ observation: ObservedRetainedFileVersion,
        for session: DocumentSession
    ) -> Bool {
        let sessionIdentity = ObjectIdentifier(session)
        // An explicit Reload/Keep Mine resolves the indeterminate destination itself. Only
        // now may it replace any prior source binding/proof with the destination observation.
        if let context = indeterminateSessionWriteContexts[sessionIdentity],
           context.location == observation.location
        {
            adoptAnchoredFileBinding(
                AnchoredWorkspaceSessionFileBinding(
                    location: context.location,
                    identity: observation.identity,
                    sha256Digest: observation.sha256Digest
                ),
                for: session,
                preparedImageAssetAuthority: observation.preparedImageAssetAuthority
            )
            return true
        }
        if let binding = anchoredSessionFileBindings[sessionIdentity] {
            guard binding.location == observation.location else { return false }
            adoptAnchoredFileBinding(
                AnchoredWorkspaceSessionFileBinding(
                    location: binding.location,
                    identity: observation.identity,
                    sha256Digest: observation.sha256Digest
                ),
                for: session,
                preparedImageAssetAuthority: observation.preparedImageAssetAuthority
            )
            return true
        }
        if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[sessionIdentity] {
            guard proof.location == observation.location else { return false }
            let installedLocation = proof.identity == observation.identity
                ? proof.installedWorkspaceLocation
                : nil
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(
                UnanchoredManagedSessionFileProof(
                    location: proof.location,
                    identity: observation.identity,
                    sha256Digest: observation.sha256Digest,
                    installedWorkspaceLocation: installedLocation
                )
            )
            if let installedLocation {
                installEditorImageAssetDocumentAuthority(
                    for: session,
                    location: installedLocation,
                    identity: observation.identity,
                    preparedAuthority: observation.preparedImageAssetAuthority,
                    allowsBootstrapWithoutRetainedLineage: false
                )
            } else {
                discardEditorImageAssetDocumentAuthority(for: session)
            }
            return true
        }
        return false
    }

    func adoptAnchoredFileBinding(
        _ binding: AnchoredWorkspaceSessionFileBinding,
        for session: DocumentSession,
        preparedImageAssetAuthority: PreparedEditorImageAssetDocumentAuthority? = nil,
        allowsImageAssetAuthorityBootstrap: Bool? = nil
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        let hadRetainedOwnership = anchoredSessionFileBindings[sessionIdentity] != nil
            || unanchoredManagedSessionOwnershipProofs[sessionIdentity] != nil
            || indeterminateSessionWriteContexts[sessionIdentity] != nil
        anchoredSessionFileBindings[sessionIdentity] = binding
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
        installEditorImageAssetDocumentAuthority(
            for: session,
            location: binding.location,
            identity: binding.identity,
            preparedAuthority: preparedImageAssetAuthority,
            allowsBootstrapWithoutRetainedLineage: allowsImageAssetAuthorityBootstrap
                ?? !hadRetainedOwnership
        )
    }

    /// Handles a background-observed possible external change to an unanchored (single-file,
    /// non-workspace) managed session using one coherent read of its retained authority.
    func handleUnanchoredExternalChange(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        // An indeterminate write's own reconciliation flow owns this session's disk state;
        // `save`/autosave already refuse independently while it is pending, and any retained
        // proof here predates the indeterminate write, so this must not act on it.
        guard indeterminateSessionWrites[sessionIdentity] == nil else { return }
        guard case let .proven(proof)? =
            unanchoredManagedSessionOwnershipProofs[sessionIdentity]
        else {
            guard let url = sessionStateURL(for: session) else { return }
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                markSessionDetachedFromMissingFile(session, url: url)
                return
            }
            return
        }

        let url = proof.location.fileURL
        do {
            let observation = try observeRetainedFileVersion(for: session)
            let changed = observedRetainedFileVersionDiffers(observation, for: session)
            guard reconcileObservedRetainedFileVersion(
                observation,
                for: session,
                canonicalURL: url
            ) else {
                return
            }
            if changed {
                guard adoptObservedRetainedFileVersion(observation, for: session) else {
                    recordExternalChangeConflict(
                        observation,
                        for: session,
                        canonicalURL: url
                    )
                    return
                }
            }
        } catch WorkspaceAnchoredFileSystemError.missing {
            markSessionDetachedFromMissingFile(session, url: url)
        } catch {
            // An unreadable/symlink/replaced namespace cannot authorize a proof update.
        }
    }

    private func retainInstalledWorkspaceMembershipIfAvailable(
        for session: DocumentSession,
        proof: UnanchoredManagedSessionFileProof
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        if proof.installedWorkspaceLocation != nil { return }
        guard let installedWorkspaceLocation = installedWorkspaceLocation(
            for: proof.location.fileURL,
            identity: proof.identity
        )
        else {
            return
        }
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(
            UnanchoredManagedSessionFileProof(
                location: proof.location,
                identity: proof.identity,
                sha256Digest: proof.sha256Digest,
                installedWorkspaceLocation: installedWorkspaceLocation
            )
        )
        installEditorImageAssetDocumentAuthority(
            for: session,
            location: installedWorkspaceLocation,
            identity: proof.identity,
            preparedAuthority: nil,
            allowsBootstrapWithoutRetainedLineage: false
        )
    }

    private func installedWorkspaceLocation(
        for fileURL: URL,
        identity: WorkspaceFileSystemIdentity
    ) -> WorkspaceFileSystemLocation? {
        guard let installedAuthority = workspaceSearchRootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration,
              let location = try? installedAuthority.canonicalizedLocation(
                  forFileURL: fileURL
              ),
              let inspection = try? WorkspaceNoFollowFileInspector.inspectFileTarget(at: location),
              inspection.canonicalLocation == location,
              case let .regular(installedIdentity) = inspection.state,
              installedIdentity == identity
        else {
            return nil
        }
        return location
    }
}
