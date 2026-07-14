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

@MainActor
extension AppState {
    /// Captures physical ownership once, when an unanchored session first becomes App-managed.
    /// Later Save Copy arbitration consumes only this retained proof and never re-inspects the
    /// session's mutable display URL.
    func retainUnanchoredManagedSessionOwnership(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        guard anchoredSessionFileBindings[sessionIdentity] == nil,
              indeterminateSessionWriteContexts[sessionIdentity] == nil
        else {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
            return
        }
        if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[sessionIdentity] {
            retainInstalledWorkspaceMembershipIfAvailable(
                for: sessionIdentity,
                proof: proof
            )
            return
        }
        guard unanchoredManagedSessionOwnershipProofs[sessionIdentity] == nil else { return }
        guard let fileURL = session.fileURL else {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .unavailable(fileURL: nil)
            return
        }

        do {
            let location = try WorkspaceFileSystemLocation(fileURL: fileURL)
            let loaded = try fileStore.loadResult(at: location)
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(
                UnanchoredManagedSessionFileProof(
                    location: location,
                    identity: loaded.metadata.identity,
                    sha256Digest: loaded.sha256Digest,
                    installedWorkspaceLocation: installedWorkspaceLocation(
                        for: location.fileURL,
                        identity: loaded.metadata.identity
                    )
                )
            )
        } catch {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .unavailable(fileURL: fileURL)
        }
    }

    func retainUnanchoredManagedSessionOwnership(
        for session: DocumentSession,
        location: WorkspaceFileSystemLocation,
        identity: WorkspaceFileSystemIdentity,
        sha256Digest: String
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard anchoredSessionFileBindings[sessionIdentity] == nil,
              indeterminateSessionWriteContexts[sessionIdentity] == nil
        else {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
            return
        }
        if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[sessionIdentity] {
            retainInstalledWorkspaceMembershipIfAvailable(
                for: sessionIdentity,
                proof: proof
            )
            return
        }
        guard unanchoredManagedSessionOwnershipProofs[sessionIdentity] == nil else { return }
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(
            UnanchoredManagedSessionFileProof(
                location: location,
                identity: identity,
                sha256Digest: sha256Digest,
                installedWorkspaceLocation: installedWorkspaceLocation(
                    for: location.fileURL,
                    identity: identity
                )
            )
        )
    }

    func exactFileURLSpellingMatches(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path(percentEncoded: false).utf8.elementsEqual(
            rhs.path(percentEncoded: false).utf8
        )
    }

    /// Accepts a file version already observed by external-change handling while keeping the
    /// session bound to its retained lexical location and workspace membership. A later save
    /// still fails closed if the leaf changes again after this coherent read.
    @discardableResult
    func refreshUnanchoredManagedSessionOwnershipFromDisk(
        for session: DocumentSession
    ) -> Bool {
        let sessionIdentity = ObjectIdentifier(session)
        guard case let .proven(proof)? =
            unanchoredManagedSessionOwnershipProofs[sessionIdentity]
        else {
            return false
        }

        do {
            let loaded = try fileStore.loadResult(at: proof.location)
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(
                UnanchoredManagedSessionFileProof(
                    location: proof.location,
                    identity: loaded.metadata.identity,
                    sha256Digest: loaded.sha256Digest,
                    installedWorkspaceLocation: proof.installedWorkspaceLocation
                )
            )
            return true
        } catch {
            return false
        }
    }

    private func retainInstalledWorkspaceMembershipIfAvailable(
        for sessionIdentity: ObjectIdentifier,
        proof: UnanchoredManagedSessionFileProof
    ) {
        guard proof.installedWorkspaceLocation == nil,
              let installedWorkspaceLocation = installedWorkspaceLocation(
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
