import Darwin
import Foundation

/// The artifact family one export operation may publish (`docs/export-gates.md` D3/D4).
public enum ExportArtifactKind: Sendable, Equatable {
    case html
    case pdf

    /// Lowercase ASCII filename extensions accepted for this kind. Comparison is ASCII
    /// case-insensitive; any other extension, or a leaf without a base name, is refused.
    public var allowedExtensions: [String] {
        switch self {
        case .html: ["html", "htm"]
        case .pdf: ["pdf"]
        }
    }
}

/// What the owner approved for the selected leaf.
public enum ExportArtifactDisposition: Sendable, Equatable {
    /// The selected leaf must be proven missing; publication uses `RENAME_EXCL`.
    case createNew
    /// The owner confirmed replacing this exact regular-file identity; publication uses
    /// `RENAME_SWAP` and is refused if any other identity, type, or absence is observed.
    case replaceConfirmed(WorkspaceFileSystemIdentity)
}

/// Exactly one panel URL plus the bytes for exactly one operation.
///
/// The request is non-copyable and `ExportArtifactWriter.write` consumes it, so one request
/// value cannot drive a second write. The writer never bookmarks, caches, or journals the URL.
public struct ExportArtifactWriteRequest: ~Copyable, Sendable {
    public let destinationURL: URL
    public let kind: ExportArtifactKind
    public let disposition: ExportArtifactDisposition
    public let bytes: Data

    public init(
        destinationURL: URL,
        kind: ExportArtifactKind,
        disposition: ExportArtifactDisposition,
        bytes: Data
    ) {
        self.destinationURL = destinationURL
        self.kind = kind
        self.disposition = disposition
        self.bytes = bytes
    }
}

/// The injected answer from the authoritative App ownership inventory.
public enum ExportArtifactOwnershipDecision: Sendable, Equatable {
    case permitted
    case refused
}

/// Synchronous, non-escaping ownership capability. It receives the writer's own no-follow
/// inspection of the selected leaf (canonical location, observed state/identity, and parent
/// case sensitivity). The inspection's location is valid only for the duration of the call.
public typealias ExportArtifactOwnershipCheck =
    (WorkspaceNoFollowFileTargetInspection) -> ExportArtifactOwnershipDecision

/// Why an operation ended with the selected leaf proven in (or restored to) its pre-operation
/// state and no operation entry remaining. A rollback may have briefly published writer bytes.
public enum ExportArtifactFailure: Error, Sendable, Equatable {
    case invalidDestinationURL
    case unsupportedExtension
    /// The exact grant could not open or anchor the selected parent directory.
    case parentAuthorityUnavailable
    case symbolicLinkInParentPath
    case symbolicLinkDestination
    case nonRegularDestination
    /// The selected spelling reaches an existing entry spelled differently on disk
    /// (case or Unicode-normalization alias).
    case destinationAlias
    case destinationAlreadyExists
    case destinationMissing
    case destinationIdentityChanged
    case ownedDestination
    /// The volume does not report `RENAME_EXCL` (and, for replacement, `RENAME_SWAP`).
    case unsupportedVolumeSemantics
    /// The exclusive staging create was denied (`EPERM`/`EACCES`): no parent/staging authority.
    case stagingNotPermitted(code: Int32)
    case stagingUnavailable(code: Int32)
    case namespaceChanged
    case cancelled
    case writeFailed(WorkspaceAnchoredFileSystemError)
}

/// Whose bytes a retained entry held when the writer re-observed it.
public enum ExportArtifactResidueContents: Sendable, Equatable {
    /// The owner-approved identity that a replacement displaced: the user's original file.
    case displacedOriginal
    /// The writer's staged artifact bytes.
    case writerBytes
    /// The entry matched neither identity when re-observed.
    case unknown
}

/// An exact path that may still hold an operation identity after an uncertain outcome.
public enum ExportArtifactResidue: Sendable, Equatable {
    /// Every tracked name was proven not to hold the operation identity.
    case none
    /// The expected identity was observed at this exact path, holding these contents.
    case retained(URL, holding: ExportArtifactResidueContents)
    /// Removal could not be proven; this exact path must be inspected before reuse.
    case removalIndeterminate(URL)

    public var url: URL? {
        switch self {
        case .none: nil
        case let .retained(url, _), let .removalIndeterminate(url): url
        }
    }
}

/// What the writer could prove about the selected leaf when it could not report success.
public enum ExportArtifactDestinationState: Sendable, Equatable {
    /// The writer bytes are durably published at the selected leaf, but cleanup was not proven.
    case holdsWriterBytes
    /// The selected leaf was proven to hold its pre-operation state.
    case provenUnchanged
    /// Publication or rollback continuity could not be proven.
    case unknown
}

public struct ExportArtifactCommit: Sendable, Equatable {
    /// The exact panel URL spelling.
    public let selectedURL: URL
    /// Final metadata sampled from the published descriptor.
    public let metadata: WorkspaceCoherentFileMetadata
}

/// Committed-but-uncertain or non-committed-with-residue. Never a success and never an
/// identity-atomic non-commit: both identities may remain and are reported by exact path.
public struct ExportArtifactIndeterminateWrite: Sendable, Equatable {
    public let reason: WorkspaceAnchoredFileSystemError
    /// The exact panel URL spelling.
    public let selectedURL: URL
    public let destinationState: ExportArtifactDestinationState
    public let residue: ExportArtifactResidue
    /// The exact operation-scoped staging (or cleanup) sibling that may still hold an identity.
    /// When the residue is the selected leaf itself this is the unproven staging name; `nil`
    /// only when no staging or cleanup name remains uncertain.
    public let stagingURL: URL?
}

public enum ExportArtifactWriteOutcome: Sendable, Equatable {
    /// Writer bytes are durable at the selected leaf and the staging name is proven absent.
    case committed(ExportArtifactCommit)
    /// The destination is proven in (or restored to) its pre-operation state and no operation
    /// entry remains.
    case notCommitted(ExportArtifactFailure)
    case indeterminate(ExportArtifactIndeterminateWrite)
}

/// The panel-time observation a caller needs before choosing a disposition.
public enum ExportArtifactDestinationInspection: Sendable, Equatable {
    case newLeaf
    case existingRegularFile(WorkspaceFileSystemIdentity)
    case refused(ExportArtifactFailure)
}

/// One-shot, non-retained artifact writer (`docs/export-gates.md` D5, PR E).
///
/// It consumes one panel URL plus bytes, anchors the selected parent through ephemeral no-follow
/// descriptors under that exact URL's security scope, and publishes through the existing
/// `WorkspaceAnchoredFileSystem` staging/`RENAME_EXCL`/`RENAME_SWAP`/postflight/rollback
/// primitives. It holds no bookmark, journal, session, or recovery authority, never widens a
/// leaf grant to its parent, never falls back to a direct or alternate-directory write, and
/// releases every descriptor before returning.
public enum ExportArtifactWriter {
    /// Inspects the selected leaf without writing, for choosing `createNew` or
    /// `replaceConfirmed(identity)` right after the panel returns.
    public static func inspectDestination(
        at destinationURL: URL,
        kind: ExportArtifactKind
    ) -> ExportArtifactDestinationInspection {
        inspectDestination(at: destinationURL, kind: kind, hooks: .production)
    }

    public static func write(
        _ request: consuming ExportArtifactWriteRequest,
        ownership: ExportArtifactOwnershipCheck
    ) -> ExportArtifactWriteOutcome {
        write(request, ownership: ownership, hooks: .production)
    }

    static func inspectDestination(
        at destinationURL: URL,
        kind: ExportArtifactKind,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactDestinationInspection {
        let selection: ExportArtifactSelection
        switch ExportArtifactSelection.parse(destinationURL, kind: kind) {
        case let .success(parsed): selection = parsed
        case let .failure(failure): return .refused(failure)
        }
        return SecurityScopedAccess.withAccess(to: destinationURL) {
            switch preflight(selection, hooks: hooks) {
            case let .failure(failure):
                .refused(failure)
            case let .success(preflight):
                switch preflight.inspection.state {
                case .missing:
                    .newLeaf
                case let .regular(identity):
                    .existingRegularFile(identity)
                }
            }
        }
    }

    static func write(
        _ request: consuming ExportArtifactWriteRequest,
        ownership: ExportArtifactOwnershipCheck,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactWriteOutcome {
        let destinationURL = request.destinationURL
        let disposition = request.disposition
        let bytes = request.bytes
        let selection: ExportArtifactSelection
        switch ExportArtifactSelection.parse(destinationURL, kind: request.kind) {
        case let .success(parsed): selection = parsed
        case let .failure(failure): return .notCommitted(failure)
        }
        return SecurityScopedAccess.withAccess(to: destinationURL) {
            performWrite(
                bytes,
                selection: selection,
                disposition: disposition,
                ownership: ownership,
                hooks: hooks
            )
        }
    }
}
