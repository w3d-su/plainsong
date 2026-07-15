import Foundation
import MarkdownCore

/// Opaque identity for one App-owned editor model binding.
///
/// This is deliberately separate from `EditorDocumentIdentity`: an optional document
/// identity describes navigation, while this value proves which exact model binding the
/// live EditorKit coordinator installed.
public struct EditorDocumentBindingID: Hashable, Sendable {
    private let rawValue: UUID

    public init() {
        rawValue = UUID()
    }
}

/// Opaque identity for one live EditorKit coordinator installation lifetime.
///
/// Multiple coordinators can install the same App-owned binding concurrently. This
/// identity distinguishes those exact installations without changing document or
/// binding identity.
public struct EditorDocumentBindingInstallationID: Hashable, Sendable {
    private let rawValue: UUID

    public init() {
        rawValue = UUID()
    }
}

/// Exact binding/coordinator pair used for idempotent lifecycle ownership.
public struct EditorDocumentBindingInstallation: Hashable, Sendable {
    public let bindingID: EditorDocumentBindingID
    public let installationID: EditorDocumentBindingInstallationID

    public init(
        bindingID: EditorDocumentBindingID,
        installationID: EditorDocumentBindingInstallationID
    ) {
        self.bindingID = bindingID
        self.installationID = installationID
    }
}

/// Exact model state on which one installed editor buffer is based.
///
/// `revision` is App-owned and monotonic for one `DocumentSession`; `source` is retained
/// so a marked-text commit can be reconciled if another accepted mutation advanced the
/// model while the composition was pending. Equality is revision plus the literal UTF-16
/// source sequence; canonical Unicode equivalence is intentionally insufficient.
public struct EditorDocumentSourceSnapshot: Equatable, Sendable {
    public let source: String
    public let revision: Int

    public init(source: String, revision: Int) {
        self.source = source
        self.revision = revision
    }

    public static func == (
        lhs: EditorDocumentSourceSnapshot,
        rhs: EditorDocumentSourceSnapshot
    ) -> Bool {
        lhs.revision == rhs.revision
            && ExactSourceText.matches(lhs.source, rhs.source)
    }
}

/// One exact whole-source publication from an installed editor coordinator.
public struct EditorDocumentSourcePublication: Equatable, Sendable {
    public let installation: EditorDocumentBindingInstallation
    public let base: EditorDocumentSourceSnapshot
    public let source: String

    public init(
        installation: EditorDocumentBindingInstallation,
        base: EditorDocumentSourceSnapshot,
        source: String
    ) {
        self.installation = installation
        self.base = base
        self.source = source
    }

    public static func == (
        lhs: EditorDocumentSourcePublication,
        rhs: EditorDocumentSourcePublication
    ) -> Bool {
        lhs.installation == rhs.installation
            && lhs.base == rhs.base
            && ExactSourceText.matches(lhs.source, rhs.source)
    }
}

/// Synchronous publication result returned before EditorKit settles pending input.
public enum EditorDocumentSourcePublicationResult: Equatable, Sendable {
    /// The source was accepted directly or reconciled with a newer non-overlapping edit.
    case accepted(
        EditorDocumentSourceSnapshot,
        sourceWasReconciled: Bool
    )
    /// The exact installation no longer owns the write, or reconciliation was unsafe.
    case rejected(EditorDocumentSourceSnapshot)
}

/// Exact writer ownership requests emitted before native input is accepted and on release.
public enum EditorDocumentWriterEvent: Equatable, Sendable {
    case activate(
        EditorDocumentBindingInstallation,
        from: EditorDocumentSourceSnapshot
    )
    case release(EditorDocumentBindingInstallation)
}

/// App-owned result of an exact writer ownership request.
///
/// EditorKit may return `true` to AppKit's native mutation path only for `activated`.
/// `synchronize` fences a still-live but stale installation and supplies the exact
/// current model snapshot. EditorKit may reacquire before the same native mutation
/// only when the view already contains that literal source; otherwise the event is
/// rejected after the current source is installed for a later retry.
public enum EditorDocumentWriterEventResult: Equatable, Sendable {
    case activated(EditorDocumentSourceSnapshot)
    case synchronize(EditorDocumentSourceSnapshot)
    case rejected(EditorDocumentSourceSnapshot)
    case released
    case releaseRejected
}

/// Installation-scoped pending writer work.
///
/// This fence covers both native source that is visible in EditorKit but not yet in
/// the model and an authorized asynchronous mutation that may create external side
/// effects before publishing source. `synchronized` is emitted only after every
/// overlapping source or asynchronous mutation lease has settled.
public enum EditorDocumentPendingSourceEvent: Equatable, Sendable {
    case began(EditorDocumentBindingInstallation)
    case synchronized(EditorDocumentBindingInstallation)
    case abandoned(EditorDocumentBindingInstallation)
}

/// Diagnostic classification for literal whole-source comparisons performed while
/// activating an App-backed writer. The current-revision path must not emit either
/// event; comparisons are reserved for exceptional synchronization/recovery paths.
public enum EditorDocumentSourceFullComparisonKind: Hashable, Sendable {
    case applicationSource
    case nativeView
}

public typealias EditorDocumentSourceSynchronizer = @MainActor (
    EditorDocumentSourceSnapshot
) -> Bool

/// App-owned source and ownership callbacks for one editor model binding.
///
/// The ordinary `Binding<String>` remains the display/highlight bridge. All App-backed
/// editor mutations flow through `publish`, which carries exact coordinator provenance.
public struct EditorDocumentSourceContract {
    public let bindingID: EditorDocumentBindingID
    let snapshot: () -> EditorDocumentSourceSnapshot
    let lifecycle: (EditorDocumentBindingLifecycleEvent) -> Void
    let writer: (EditorDocumentWriterEvent) -> EditorDocumentWriterEventResult
    let pendingSource: (EditorDocumentPendingSourceEvent) -> Void
    let publish: (EditorDocumentSourcePublication) -> EditorDocumentSourcePublicationResult
    let recordFullSourceComparison: (EditorDocumentSourceFullComparisonKind) -> Void
    let registerSourceSynchronizer: (
        EditorDocumentBindingInstallation,
        @escaping EditorDocumentSourceSynchronizer
    ) -> Void
    let unregisterSourceSynchronizer: (EditorDocumentBindingInstallation) -> Void

    public init(
        bindingID: EditorDocumentBindingID,
        snapshot: @escaping () -> EditorDocumentSourceSnapshot,
        lifecycle: @escaping (EditorDocumentBindingLifecycleEvent) -> Void,
        writer: @escaping (EditorDocumentWriterEvent) -> EditorDocumentWriterEventResult,
        pendingSource: @escaping (EditorDocumentPendingSourceEvent) -> Void,
        publish: @escaping (EditorDocumentSourcePublication) -> EditorDocumentSourcePublicationResult,
        recordFullSourceComparison: @escaping (EditorDocumentSourceFullComparisonKind) -> Void = { _ in },
        registerSourceSynchronizer: @escaping (
            EditorDocumentBindingInstallation,
            @escaping EditorDocumentSourceSynchronizer
        ) -> Void = { _, _ in },
        unregisterSourceSynchronizer: @escaping (
            EditorDocumentBindingInstallation
        ) -> Void = { _ in }
    ) {
        self.bindingID = bindingID
        self.snapshot = snapshot
        self.lifecycle = lifecycle
        self.writer = writer
        self.pendingSource = pendingSource
        self.publish = publish
        self.recordFullSourceComparison = recordFullSourceComparison
        self.registerSourceSynchronizer = registerSourceSynchronizer
        self.unregisterSourceSynchronizer = unregisterSourceSynchronizer
    }
}

/// Installation lifecycle emitted by the live editor bridge.
public enum EditorDocumentBindingLifecycleEvent: Equatable, Sendable {
    case installed(EditorDocumentBindingInstallation)
    case revoked(EditorDocumentBindingInstallation)
}
