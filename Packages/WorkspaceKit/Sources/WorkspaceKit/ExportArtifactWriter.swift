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

/// Leaf-path metadata for one selected destination (`docs/export-gates.md` D5, amended
/// 2026-09-29). It is derived without opening, enumerating, or anchoring the chosen folder:
/// - `state` comes from `fstatat(AT_FDCWD, leaf, …, AT_SYMLINK_NOFOLLOW_ANY)`, so no path
///   component may be a symbolic link;
/// - an existing leaf is opened no-follow and its `fcntl(F_GETPATH)` spelling must equal the
///   selected spelling byte for byte, so a case or normalization alias never inspects;
/// - `parentIdentity` is the parent path's no-follow `fstatat` identity (metadata only);
/// - `volumeIsCaseSensitive` is the parent URL's `volumeSupportsCaseSensitiveNames`.
public struct ExportArtifactLeafInspection: Sendable, Equatable {
    public let state: WorkspaceNoFollowFileTargetState
    /// The exact selected leaf spelling as a literal file URL (no Foundation normalization).
    public let leafURL: URL
    public let parentIdentity: WorkspaceFileSystemIdentity
    public let volumeIsCaseSensitive: Bool

    public init(
        state: WorkspaceNoFollowFileTargetState,
        leafURL: URL,
        parentIdentity: WorkspaceFileSystemIdentity,
        volumeIsCaseSensitive: Bool
    ) {
        self.state = state
        self.leafURL = leafURL
        self.parentIdentity = parentIdentity
        self.volumeIsCaseSensitive = volumeIsCaseSensitive
    }
}

/// Synchronous, non-escaping ownership capability. It receives the writer's own leaf-path
/// inspection of the selected destination.
public typealias ExportArtifactOwnershipCheck =
    (ExportArtifactLeafInspection) -> ExportArtifactOwnershipDecision

/// Why an operation ended without publishing (or after provably reversing its publication)
/// with no operation entry remaining: the staged file and the item-replacement directory
/// were proven absent.
public enum ExportArtifactFailure: Error, Sendable, Equatable {
    case invalidDestinationURL
    case unsupportedExtension
    /// The parent path's metadata could not be read, or it is not a directory.
    case parentAuthorityUnavailable
    case symbolicLinkInParentPath
    case symbolicLinkDestination
    case nonRegularDestination
    /// The selected spelling reaches an existing entry spelled differently on disk
    /// (case or Unicode-normalization alias).
    case destinationAlias
    /// The existing leaf could not be opened to prove its canonical spelling.
    case destinationUnreadable(code: Int32)
    case destinationAlreadyExists
    case destinationMissing
    case destinationIdentityChanged
    case ownedDestination
    /// The destination volume does not advertise both `RENAME_EXCL` and `RENAME_SWAP`.
    case unsupportedVolumeSemantics
    /// Foundation could not establish an item-replacement directory, or it is not a directory.
    case stagingDirectoryUnavailable
    /// The item-replacement directory is on a different device; there is no copy fallback.
    case stagingDirectoryOnDifferentDevice
    /// The item-replacement directory is the chosen folder or lies inside it.
    case stagingDirectoryInsideDestinationFolder
    /// The exclusive staged-file create was denied (`EPERM`/`EACCES`).
    case stagingNotPermitted(code: Int32)
    case stagingUnavailable(code: Int32)
    /// `renameatx_np` onto the exact leaf was denied (`EPERM`/`EACCES`).
    case publicationNotPermitted(code: Int32)
    /// `NSFileCoordinator` did not run the publication for a ubiquitous destination.
    case coordinationFailed
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

/// An exact path inside the item-replacement directory that may still hold an identity after
/// an uncertain outcome. The writer never leaves an entry in the chosen folder other than the
/// selected leaf itself.
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
    /// The writer bytes were proven published at the selected leaf, but cleanup was not proven.
    case holdsWriterBytes
    /// The operation never changed the selected leaf, or proved it restored the pre-operation
    /// identity there.
    case provenUnchanged
    /// Publication or its reversal could not be proven.
    case unknown
}

public struct ExportArtifactCommit: Sendable, Equatable {
    /// The exact panel URL spelling.
    public let selectedURL: URL
    /// Final metadata sampled from the published leaf by no-follow `fstatat`.
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
    /// The exact staged-file path inside the item-replacement directory, or `nil` when that
    /// name was proven to hold no entry.
    public let stagingURL: URL?
    /// The operation's exact item-replacement directory, or `nil` when it was proven removed.
    public let itemReplacementDirectoryURL: URL?
    /// True when `residue` lies inside the item-replacement directory: a hidden temporary
    /// folder (inside the app container on the internal volume) that the OS may purge. When the
    /// residue holds `.displacedOriginal`, the user must be told to recover it promptly; the
    /// location is not durable.
    public let residueIsInPurgeableTemporaryFolder: Bool
}

public enum ExportArtifactWriteOutcome: Sendable, Equatable {
    /// Writer bytes are at the selected leaf, and the staged name, any displaced original, and
    /// the item-replacement directory are proven absent.
    case committed(ExportArtifactCommit)
    /// Nothing was published (or a publication was provably reversed) and no operation entry
    /// remains.
    case notCommitted(ExportArtifactFailure)
    case indeterminate(ExportArtifactIndeterminateWrite)
}

/// The panel-time observation a caller needs before choosing a disposition.
public enum ExportArtifactDestinationInspection: Sendable, Equatable {
    case newLeaf
    case existingRegularFile(WorkspaceFileSystemIdentity)
    case refused(ExportArtifactFailure)
}

/// One-shot, non-retained artifact writer (`docs/export-gates.md` D5, amended 2026-09-29).
///
/// A save-panel grant covers exactly the chosen leaf, so the writer never opens, enumerates,
/// or creates entries in the chosen folder other than publishing that leaf. It stages one file
/// in a same-device `FileManager` item-replacement directory, proves the leaf by path with
/// `AT_SYMLINK_NOFOLLOW_ANY`, and publishes by exact path with `renameatx_np` `RENAME_EXCL` or
/// `RENAME_SWAP` plus `RENAME_NOFOLLOW_ANY`. It holds no bookmark, journal, session, or recovery
/// authority, never falls back to a direct, copying, or alternate-directory write, and releases
/// every descriptor before returning.
public enum ExportArtifactWriter {
    /// Inspects the selected leaf without writing, for choosing `createNew` or
    /// `replaceConfirmed(identity)` right after the panel returns.
    public static func inspectDestination(
        at destinationURL: URL,
        kind: ExportArtifactKind
    ) -> ExportArtifactDestinationInspection {
        inspectDestination(at: destinationURL, kind: kind, hooks: .production)
    }

    /// The leaf-path inspection the writer hands its ownership capability, for callers that
    /// must derive the same value independently (the App ownership adapter).
    public static func inspectLeaf(
        at destinationURL: URL
    ) -> Result<ExportArtifactLeafInspection, ExportArtifactFailure> {
        let selection: ExportArtifactSelection
        switch ExportArtifactSelection.parse(destinationURL, kind: nil) {
        case let .success(parsed): selection = parsed
        case let .failure(failure): return .failure(failure)
        }
        return SecurityScopedAccess.withAccess(to: destinationURL) {
            inspect(selection, hooks: .production).map(\.inspection)
        }
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
            let proof: ExportArtifactLeafProof
            switch inspect(selection, hooks: hooks) {
            case let .success(value): proof = value.proof
            case let .failure(failure): return .refused(failure)
            }
            if let failure = volumeCapabilityFailure(selection, proof: proof, hooks: hooks) {
                return .refused(failure)
            }
            return switch proof.state {
            case .missing: .newLeaf
            case let .regular(identity): .existingRegularFile(identity)
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
