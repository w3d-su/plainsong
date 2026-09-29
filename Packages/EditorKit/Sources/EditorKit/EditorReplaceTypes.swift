import Foundation
import MarkdownCore

/// Injected commit decision for one single Replace. PR E supplies the real App
/// policy; this PR only requires the answer before writer preflight.
public struct EditorReplaceAuthorization: Sendable {
    public var allowsCommit: @Sendable () -> Bool

    public init(allowsCommit: @escaping @Sendable () -> Bool) {
        self.allowsCommit = allowsCommit
    }

    public static func allowed() -> EditorReplaceAuthorization {
        EditorReplaceAuthorization { true }
    }

    public static func refused() -> EditorReplaceAuthorization {
        EditorReplaceAuthorization { false }
    }
}

/// Plain snapshot a single Replace must agree with before it touches the editor.
public struct EditorReplaceRequest: Equatable, Sendable {
    public let documentIdentity: EditorDocumentIdentity?
    public let sourceRevision: UInt64
    public let queryGeneration: UInt64
    public let session: EditorFindSession
    public let replacement: String

    public init(
        documentIdentity: EditorDocumentIdentity?,
        sourceRevision: UInt64,
        queryGeneration: UInt64,
        session: EditorFindSession,
        replacement: String
    ) {
        self.documentIdentity = documentIdentity
        self.sourceRevision = sourceRevision
        self.queryGeneration = queryGeneration
        self.session = session
        self.replacement = replacement
    }
}

/// Why a single Replace did not change the source.
public enum EditorReplaceRefusal: Equatable, Sendable, Error {
    case staleIdentity
    case staleRevision
    case staleQueryGeneration
    case staleSession
    case noCurrentMatch
    case markedText
    case unauthorized
    /// Experimental WYSIWYG fold/image presentation is installed. PR F lifts this.
    case wysiwygPresentationInstalled
    case invalidPlan(EditorReplacePlanRefusal)
    case writerPreflightFailed
    /// Writer preflight passed, but the observed post-write snapshot is still
    /// the pre-write source at the pre-write revision: native insertion was
    /// refused or its publication was rejected and restored.
    case writeNotApplied
}

/// Result of one single Replace. No STTextView type crosses this boundary.
public enum EditorReplaceOutcome: Equatable, Sendable {
    /// The current match was not the applied selection. Exact navigation was
    /// emitted and nothing was queued.
    case navigatedToCurrentMatch(NSRange)
    /// The observed post-write snapshot is exactly the planned source at a newer
    /// revision. The controller consumes that revision once and continues with
    /// `afterOneReplace`; `plan.resumeUTF16` is the continuation anchor.
    case replaced(EditorReplaceOneMatchPlan)
    /// UTF-16-identical replacement. No writer, revision, undo, or rescan.
    case advancedIdentical(EditorReplaceContinuation)
    /// The native insert ran, but its result cannot be credited to this Replace:
    /// the observed snapshot is not exactly the planned text (for example an App
    /// reconciliation), is no longer observable, or a rebind / document close
    /// superseded Find during the write. No continuation runs; a changed
    /// publication is recomputed as an ordinary edit.
    case unverifiedWrite
    case refused(EditorReplaceRefusal)
}
