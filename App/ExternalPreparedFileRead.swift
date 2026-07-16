import EditorKit
import Foundation
import WorkspaceKit

struct PreparedExternalFileRead: @unchecked Sendable {
    let outcome: WorkspaceCoherentFileReadOutcome
    let payload: ExternalReloadApplicationPayload?
    let imageAssetAuthority: PreparedEditorImageAssetDocumentAuthority?
}

struct ExternalDiskInspectionReadContext {
    let canonicalURL: URL
    let location: WorkspaceFileSystemLocation
    let token: UUID
    let lifecycleGeneration: UInt64
    let diskEventGeneration: UInt64
}

func prepareExternalFileRead(
    at location: WorkspaceFileSystemLocation,
    reader: any WorkspaceCoherentFileReading,
    applicationPreparer: any ExternalReloadApplicationPreparing,
    sourceSnapshot: EditorDocumentSourceSnapshot
) async -> PreparedExternalFileRead {
    guard !Task.isCancelled else {
        return cancelledExternalFileRead(imageAssetAuthority: nil)
    }

    let authority: PreparedEditorImageAssetDocumentAuthority
    do {
        authority = try await cancellableDetachedExternalFileOperation {
            try prepareEditorImageAssetDocumentAuthority(at: location)
        }
    } catch {
        if Task.isCancelled || error is CancellationError {
            return cancelledExternalFileRead(imageAssetAuthority: nil)
        }
        return PreparedExternalFileRead(
            outcome: .namespaceChanged,
            payload: nil,
            imageAssetAuthority: nil
        )
    }

    guard !Task.isCancelled else {
        return cancelledExternalFileRead(imageAssetAuthority: authority)
    }
    let readOutcome = await reader.readCoherentFile(at: location)
    guard !Task.isCancelled else {
        return cancelledExternalFileRead(imageAssetAuthority: authority)
    }

    switch readOutcome {
    case let .loaded(snapshot):
        let authorityIsValid: Bool
        do {
            authorityIsValid = try await cancellableDetachedExternalFileOperation {
                try SecurityScopedAccess.withAccess(to: authority.location.securityScopedURL) {
                    try authority.validateLoadedIdentityAndNamespace(
                        snapshot.metadata.identity
                    )
                }
                return true
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                return cancelledExternalFileRead(imageAssetAuthority: authority)
            }
            authorityIsValid = false
        }
        guard authorityIsValid else {
            return PreparedExternalFileRead(
                outcome: .namespaceChanged,
                payload: nil,
                imageAssetAuthority: authority
            )
        }

        guard !Task.isCancelled else {
            return cancelledExternalFileRead(imageAssetAuthority: authority)
        }
        let payload = await applicationPreparer.prepare(
            snapshot: snapshot,
            sourceSnapshot: sourceSnapshot
        )
        guard !Task.isCancelled else {
            return cancelledExternalFileRead(imageAssetAuthority: authority)
        }
        return PreparedExternalFileRead(
            outcome: readOutcome,
            payload: payload,
            imageAssetAuthority: authority
        )
    case .missing, .symbolicLink, .notRegularFile, .unreadable, .invalidUTF8,
         .namespaceChanged, .unstable, .cancelled:
        return PreparedExternalFileRead(
            outcome: readOutcome,
            payload: nil,
            imageAssetAuthority: authority
        )
    }
}

private func cancellableDetachedExternalFileOperation<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    try Task.checkCancellation()
    let task = Task.detached(priority: .utility) {
        try Task.checkCancellation()
        let value = try operation()
        try Task.checkCancellation()
        return value
    }
    return try await withTaskCancellationHandler {
        let value = try await task.value
        try Task.checkCancellation()
        return value
    } onCancel: {
        task.cancel()
    }
}

private func cancelledExternalFileRead(
    imageAssetAuthority: PreparedEditorImageAssetDocumentAuthority?
) -> PreparedExternalFileRead {
    PreparedExternalFileRead(
        outcome: .cancelled,
        payload: nil,
        imageAssetAuthority: imageAssetAuthority
    )
}
