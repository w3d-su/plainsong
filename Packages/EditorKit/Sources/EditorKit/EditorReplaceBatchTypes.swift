import AppKit
import MarkdownCore

/// The product Replace All command. Preparation owns source construction; delivery
/// checks the originating editor and the final live App tuple in one main-actor turn.
@MainActor
public struct EditorReplaceBatchCommand {
    public let request: EditorReplaceRequest
    public let prepared: EditorReplacePreparedBatch
    public let authorization: EditorReplaceAuthorization
    public let controller: EditorFindController
    public let editorStamp: EditorReplaceEditorStamp
    public let installations: Set<EditorDocumentBindingInstallation>
    /// App checks its action/lifecycle tuple and all owned field editors for marked
    /// text here. The concrete editor is checked separately, immediately afterwards.
    public let recheck: @MainActor () -> EditorReplaceBatchRefusal?

    public init(
        request: EditorReplaceRequest,
        prepared: EditorReplacePreparedBatch,
        authorization: EditorReplaceAuthorization,
        controller: EditorFindController,
        editorStamp: EditorReplaceEditorStamp,
        installations: Set<EditorDocumentBindingInstallation>,
        recheck: @escaping @MainActor () -> EditorReplaceBatchRefusal?
    ) {
        self.request = request
        self.prepared = prepared
        self.authorization = authorization
        self.controller = controller
        self.editorStamp = editorStamp
        self.installations = installations
        self.recheck = recheck
    }
}

public enum EditorReplaceBatchRefusal: Equatable, Sendable, Error {
    case staleIdentity
    case staleRevision
    case staleQueryGeneration
    case staleSession
    /// The App-owned preparation tuple or a marked owned field changed.
    case superseded
    case markedText
    case unauthorized
    case invalidPlan(EditorReplacePlanRefusal)
    case writerPreflightFailed
    case writeNotApplied
}

/// Plain values for PR H's result presentation. No-op batches retain the exact
/// session, selection, ordinal, revision, and undo history.
public enum EditorReplaceBatchOutcome: Equatable, Sendable {
    case noChanges(EditorReplaceBatchPlan)
    case replaced(EditorReplaceBatchPlan)
    case unverifiedWrite
    case refused(EditorReplaceBatchRefusal)
}

public enum EditorReplaceBatchDelivery: Equatable, Sendable {
    case delivered(EditorReplaceBatchOutcome)
    case notDelivered(EditorReplaceDeliveryRefusal)
}
