import Foundation
import MarkdownCore
import WorkspaceKit

enum UnanchoredManagedSessionOwnershipProof: Equatable {
    case proven(location: WorkspaceFileSystemLocation, identity: WorkspaceFileSystemIdentity)
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
        guard unanchoredManagedSessionOwnershipProofs[sessionIdentity] == nil else { return }
        guard let fileURL = session.fileURL?.standardizedFileURL else {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .unavailable(fileURL: nil)
            return
        }

        do {
            let location = try WorkspaceFileSystemLocation(fileURL: fileURL)
            let inspection = try WorkspaceNoFollowFileInspector.inspectFileTarget(at: location)
            guard inspection.canonicalLocation == location,
                  case let .regular(identity) = inspection.state
            else {
                unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .unavailable(
                    fileURL: fileURL
                )
                return
            }
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(
                location: location,
                identity: identity
            )
        } catch {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .unavailable(fileURL: fileURL)
        }
    }

    func retainUnanchoredManagedSessionOwnership(
        for session: DocumentSession,
        location: WorkspaceFileSystemLocation,
        identity: WorkspaceFileSystemIdentity
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard anchoredSessionFileBindings[sessionIdentity] == nil,
              indeterminateSessionWriteContexts[sessionIdentity] == nil
        else {
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
            return
        }
        guard unanchoredManagedSessionOwnershipProofs[sessionIdentity] == nil else { return }
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(
            location: location,
            identity: identity
        )
    }
}
