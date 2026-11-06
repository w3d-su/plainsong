import Foundation
import MarkdownCore
import WorkspaceKitIOS

struct IOSCloudVersionReopenFailure: Error {}

extension IOSDocumentSceneController {
    func reviewVersions(_ identity: IOSDocumentIdentity) async throws -> IOSCloudVersionReview {
        guard handle?.identity == identity, let store = documents as? IOSUIDocumentStore else {
            throw IOSDocumentFailure.documentChanged
        }
        try beginTransition()
        defer { finishTransition() }
        return try await store.reviewCloudVersions(for: identity)
    }

    func chooseVersion(_ id: UUID, from review: IOSCloudVersionReview) async throws {
        guard let handle, handle.identity == review.revision.documentID, let store = documents as? IOSUIDocumentStore
        else { throw IOSDocumentFailure.documentChanged }
        try beginTransition()
        defer { finishTransition() }
        try await store.applyCloudVersion(id, from: review)
        // Reopen from the provider under the existing grant, with a fresh editor
        // binding and undo history for the selected bytes.
        do {
            try await closeCurrent()
            try await install(handle.location, initialText: nil)
        } catch {
            throw IOSCloudVersionReopenFailure()
        }
    }
}
