import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

// External Reload / Keep Mine / inspection bookkeeping, moved verbatim from
// `AppState.swift` so that file stays under SwiftLint's 1000-line limit.

struct ExternalReloadTask {
    let token: UUID
    let generation: UInt64
    let session: DocumentSession
    let canonicalURL: URL
    let location: WorkspaceFileSystemLocation
    let lifecycleGeneration: UInt64
    let sourceSnapshot: EditorDocumentSourceSnapshot
    let diskEventGeneration: UInt64
    let intent: DeferredExternalChangeResolution
    let task: Task<Void, Never>
}

struct ExternalDiskInspectionTask {
    let token: UUID
    let session: DocumentSession
    let canonicalURL: URL
    let location: WorkspaceFileSystemLocation
    let lifecycleGeneration: UInt64
    let diskEventGeneration: UInt64
    let sourceSnapshot: EditorDocumentSourceSnapshot
    let task: Task<Void, Never>
}

struct PendingExternalReloadApplication {
    let token: UUID
    let generation: UInt64
    let session: DocumentSession
    let canonicalURL: URL
    let payload: ExternalReloadApplicationPayload
    let preparedImageAssetAuthority: PreparedEditorImageAssetDocumentAuthority?
    let acceptedSourceSnapshot: EditorDocumentSourceSnapshot
    let intent: DeferredExternalChangeResolution
    var synchronizedInstallations: Set<EditorDocumentBindingInstallation>
}

struct ExternalReloadApplicationPayload {
    let snapshot: WorkspaceCoherentFileSnapshot
    let contentHash: String
    let textTransition: DocumentSessionTextTransition

    private nonisolated init(
        snapshot: WorkspaceCoherentFileSnapshot,
        contentHash: String,
        textTransition: DocumentSessionTextTransition
    ) {
        self.snapshot = snapshot
        self.contentHash = contentHash
        self.textTransition = textTransition
    }

    nonisolated static func preparingIfNotCancelled(
        snapshot: WorkspaceCoherentFileSnapshot,
        sourceSnapshot: EditorDocumentSourceSnapshot
    ) -> Self? {
        guard !Task.isCancelled else { return nil }
        let textTransition = DocumentSessionTextTransition(
            sourceText: sourceSnapshot.source,
            sourceRevision: sourceSnapshot.revision,
            destinationText: snapshot.text
        )
        guard !Task.isCancelled else { return nil }
        return Self(
            snapshot: snapshot,
            contentHash: snapshot.sha256Digest,
            textTransition: textTransition
        )
    }
}
