import Foundation
import MarkdownCore

public struct IOSSourceEditorSnapshot: Sendable {
    public let bindingID: UUID
    public let revision: IOSDocumentRevision
    public let document: DocumentSnapshot
    public let selection: NSRange
    public let visibleRange: NSRange
    public let selectionGeneration: UInt64
    public let accessGeneration: UInt64
    public let hasMarkedText: Bool
    public let canWrite: Bool
    /// Scene command ownership; an owned authoring form may retain this route.
    /// This is not simply UITextView.isFirstResponder.
    public let isFocused: Bool

    public init(
        bindingID: UUID,
        revision: IOSDocumentRevision,
        document: DocumentSnapshot,
        selection: NSRange,
        visibleRange: NSRange,
        selectionGeneration: UInt64,
        accessGeneration: UInt64,
        hasMarkedText: Bool,
        canWrite: Bool,
        isFocused: Bool
    ) {
        self.bindingID = bindingID
        self.revision = revision
        self.document = document
        self.selection = selection
        self.visibleRange = visibleRange
        self.selectionGeneration = selectionGeneration
        self.accessGeneration = accessGeneration
        self.hasMarkedText = hasMarkedText
        self.canWrite = canWrite
        self.isFocused = isFocused
    }
}

public struct IOSAuthorizedEdit: Sendable {
    public let bindingID: UUID
    public let baseRevision: IOSDocumentRevision
    public let selectionGeneration: UInt64
    public let accessGeneration: UInt64
    public let result: MarkdownEditResult
    public let undoActionName: String

    public init(
        bindingID: UUID,
        baseRevision: IOSDocumentRevision,
        selectionGeneration: UInt64,
        accessGeneration: UInt64,
        result: MarkdownEditResult,
        undoActionName: String
    ) {
        self.bindingID = bindingID
        self.baseRevision = baseRevision
        self.selectionGeneration = selectionGeneration
        self.accessGeneration = accessGeneration
        self.result = result
        self.undoActionName = undoActionName
    }
}

public enum IOSEditOutcome: Equatable, Sendable {
    case applied(IOSDocumentRevision)
    case refused(IOSEditRefusal)
}

public enum IOSEditRefusal: Error, Equatable, Sendable {
    case bindingChanged
    case documentChanged
    case sourceChanged
    case selectionChanged
    case accessChanged
    case markedText
    case readOnly
    case invalidRange
    case busy
    case notFocused
    case unavailable
}

@MainActor
public protocol IOSSourceEditorControlling: AnyObject {
    func captureSnapshot() -> IOSSourceEditorSnapshot?
    func apply(_ edit: IOSAuthorizedEdit) -> IOSEditOutcome
    func reveal(_ range: NSRange, expected: IOSDocumentRevision) -> Bool
    func undo()
    func redo()
}

/// 13 attaches the exact session owned by 05. Only 04 publishes native writes.
@MainActor
public struct IOSSourceEditorDocumentBinding {
    public let bindingID: UUID
    public let identity: IOSDocumentIdentity
    public let session: DocumentSession
    public let accessGeneration: UInt64
    public let canWrite: Bool

    public init(
        bindingID: UUID,
        identity: IOSDocumentIdentity,
        session: DocumentSession,
        accessGeneration: UInt64,
        canWrite: Bool
    ) {
        self.bindingID = bindingID
        self.identity = identity
        self.session = session
        self.accessGeneration = accessGeneration
        self.canWrite = canWrite
    }
}

public enum IOSSourceEditorEvent: Sendable {
    case snapshotChanged(IOSSourceEditorSnapshot)
    case detached(documentID: IOSDocumentIdentity, bindingID: UUID)
}

@MainActor
public protocol IOSSourceEditorBinding: IOSSourceEditorControlling {
    /// Attaching or replacing a binding fences all work from the old installation.
    func attach(_ binding: IOSSourceEditorDocumentBinding)
    func detach(expected identity: IOSDocumentIdentity, bindingID: UUID)
    func updateAccess(for identity: IOSDocumentIdentity, bindingID: UUID, generation: UInt64, canWrite: Bool)
    /// 13 changes command ownership only for the expected installed binding.
    func updateCommandFocus(for identity: IOSDocumentIdentity, bindingID: UUID, isFocused: Bool)
    /// No user edit/Undo; marked text or a busy native writer returns deferred.
    func installExternalReload(_ proposal: IOSDocumentReloadProposal) -> IOSDocumentReloadOutcome
    /// Immutable events on main. Subscriber owns/cancels the observation token.
    func observe(_ handler: @escaping @MainActor (IOSSourceEditorEvent) -> Void) -> any IOSObservation
}
