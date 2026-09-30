import Darwin
import Foundation

/// The literal panel URL split without Foundation path normalization.
struct ExportArtifactSelection {
    let destinationURL: URL
    let parentPath: String
    let leaf: String

    /// The exact selected path: the literal parent spelling joined with the literal leaf.
    var leafPath: String {
        parentPath == "/" ? "/\(leaf)" : "\(parentPath)/\(leaf)"
    }

    var leafURL: URL {
        WorkspaceLiteralFileURL.fileURL(path: leafPath, isDirectory: false)
    }

    var parentURL: URL {
        WorkspaceLiteralFileURL.fileURL(path: parentPath, isDirectory: true)
    }

    /// `kind == nil` parses a destination for ownership inspection without an extension policy.
    static func parse(
        _ url: URL,
        kind: ExportArtifactKind?
    ) -> Result<ExportArtifactSelection, ExportArtifactFailure> {
        guard url.isFileURL, !url.hasDirectoryPath,
              let path = try? WorkspaceLiteralFileURL.absolutePath(of: url)
        else {
            return .failure(.invalidDestinationURL)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let leaf = components.last,
              !components.contains(where: { $0 == "." || $0 == ".." })
        else {
            return .failure(.invalidDestinationURL)
        }
        if let kind, !hasAllowedExtension(String(leaf), kind: kind) {
            return .failure(.unsupportedExtension)
        }
        let parentPath = "/" + components.dropLast().joined(separator: "/")
        return .success(ExportArtifactSelection(
            destinationURL: url,
            parentPath: parentPath,
            leaf: String(leaf)
        ))
    }

    /// Requires a non-empty base name and an ASCII extension from the kind's allowlist.
    static func hasAllowedExtension(_ leaf: String, kind: ExportArtifactKind) -> Bool {
        let bytes = Array(leaf.utf8)
        guard let dot = bytes.lastIndex(of: 0x2E), dot > 0, dot < bytes.count - 1 else {
            return false
        }
        var extensionBytes: [UInt8] = []
        for byte in bytes[(dot + 1)...] {
            switch byte {
            case 0x41 ... 0x5A: extensionBytes.append(byte + 0x20)
            case 0x61 ... 0x7A, 0x30 ... 0x39: extensionBytes.append(byte)
            default: return false
            }
        }
        return kind.allowedExtensions.contains { $0.utf8.elementsEqual(extensionBytes) }
    }
}

/// One no-follow proof of the selected leaf and its parent path, taken by path only.
struct ExportArtifactLeafProof {
    let state: WorkspaceNoFollowFileTargetState
    let parentIdentity: WorkspaceFileSystemIdentity
    /// The existing leaf's `fstatat` result (mode, size, device); `nil` for a new leaf.
    let leafStatus: stat?
}

struct ExportArtifactPreflight {
    let proof: ExportArtifactLeafProof
    let inspection: ExportArtifactLeafInspection
}

extension ExportArtifactWriter {
    /// Proves the leaf and derives the ownership inspection value. Runs inside the caller's
    /// security scope for the exact panel URL; never starts access on, opens, or enumerates the
    /// parent directory.
    static func inspect(
        _ selection: ExportArtifactSelection,
        hooks: ExportArtifactWriterHooks
    ) -> Result<ExportArtifactPreflight, ExportArtifactFailure> {
        proveLeaf(selection, hooks: hooks).flatMap { proof in
            // A missing volume key fails closed rather than guessing a case policy.
            guard let values = try? selection.parentURL.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ), let caseSensitive = values.volumeSupportsCaseSensitiveNames else {
                return .failure(.parentAuthorityUnavailable)
            }
            return .success(ExportArtifactPreflight(
                proof: proof,
                inspection: ExportArtifactLeafInspection(
                    state: proof.state,
                    canonicalLeafURL: selection.leafURL,
                    parentIdentity: proof.parentIdentity,
                    volumeIsCaseSensitive: caseSensitive
                )
            ))
        }
    }

    /// D5 step 3: `fstatat(AT_FDCWD, …, AT_SYMLINK_NOFOLLOW_ANY)` of the parent path (must be a
    /// directory) and of the exact leaf path. Absent with a canonical parent spelling → new leaf;
    /// a regular file whose opened `F_GETPATH` spelling equals the selected spelling → existing;
    /// anything else fails closed. Either way the selected spelling is proven canonical.
    static func proveLeaf(
        _ selection: ExportArtifactSelection,
        hooks: ExportArtifactWriterHooks
    ) -> Result<ExportArtifactLeafProof, ExportArtifactFailure> {
        proveParent(selection, hooks: hooks).flatMap { parentIdentity in
            let leafStatus: stat
            switch hooks.noFollowStatus(selection.leafPath, step: .inspectLeaf) {
            case let .failure(failure):
                return switch failure.code {
                case ENOENT:
                    proveCanonicalParentSpelling(selection, hooks: hooks).map {
                        ExportArtifactLeafProof(state: .missing, parentIdentity: parentIdentity, leafStatus: nil)
                    }
                case ELOOP: .failure(.symbolicLinkInParentPath)
                case ENOTDIR: .failure(.namespaceChanged)
                default: .failure(.parentAuthorityUnavailable)
                }
            case let .success(status):
                leafStatus = status
            }
            switch leafStatus.exportFileType {
            case S_IFREG: break
            case S_IFLNK: return .failure(.symbolicLinkDestination)
            default: return .failure(.nonRegularDestination)
            }
            let identity = WorkspaceFileSystemIdentity(exportStatus: leafStatus)
            if let failure = proveCanonicalSpelling(selection, identity: identity, hooks: hooks) {
                return .failure(failure)
            }
            return .success(ExportArtifactLeafProof(
                state: .regular(identity),
                parentIdentity: parentIdentity,
                leafStatus: leafStatus
            ))
        }
    }

    /// The parent path must be a directory reached without any symlink. Metadata only: the
    /// chosen folder is never opened.
    private static func proveParent(
        _ selection: ExportArtifactSelection,
        hooks: ExportArtifactWriterHooks
    ) -> Result<WorkspaceFileSystemIdentity, ExportArtifactFailure> {
        switch hooks.noFollowStatus(selection.parentPath, step: .inspectParent) {
        case let .failure(failure):
            .failure(failure.code == ELOOP ? .symbolicLinkInParentPath : .parentAuthorityUnavailable)
        case let .success(status):
            switch status.exportFileType {
            case S_IFDIR: .success(WorkspaceFileSystemIdentity(exportStatus: status))
            case S_IFLNK: .failure(.symbolicLinkInParentPath)
            default: .failure(.parentAuthorityUnavailable)
            }
        }
    }

    /// A new leaf has no `F_GETPATH`, so the parent's kernel spelling comes from
    /// `getattrlist(ATTR_CMN_FULLPATH, FSOPT_NOFOLLOW_ANY)`, a metadata read that never opens the
    /// chosen folder. It must equal the selected parent spelling byte for byte: a firmlink
    /// (`/System/Volumes/Data/…`), case, or normalization spelling of an existing folder fails
    /// closed, so the ownership inventory only ever compares canonical full paths.
    private static func proveCanonicalParentSpelling(
        _ selection: ExportArtifactSelection,
        hooks: ExportArtifactWriterHooks
    ) -> Result<Void, ExportArtifactFailure> {
        switch hooks.fullPath(selection.parentPath, step: .inspectParent, options: FSOPT_NOFOLLOW_ANY) {
        case let .failure(failure):
            .failure(failure.code == ELOOP ? .symbolicLinkInParentPath : .parentAuthorityUnavailable)
        case let .success(kernelPath) where kernelPath.elementsEqual(selection.parentPath.utf8):
            .success(())
        case .success:
            .failure(.destinationAlias)
        }
    }

    /// Opens the existing leaf with `O_NOFOLLOW_ANY` (which subsumes `O_NOFOLLOW`; the kernel
    /// rejects the two together with `EINVAL`) and requires the kernel's `F_GETPATH` spelling of that
    /// exact identity to equal the selected spelling byte for byte. On a case- or
    /// normalization-insensitive volume `fstatat` resolves an alias to the existing entry; the
    /// kernel path names the on-disk spelling (a hard link keeps the name it was opened by), so
    /// an alias fails closed without enumerating the parent.
    private static func proveCanonicalSpelling(
        _ selection: ExportArtifactSelection,
        identity: WorkspaceFileSystemIdentity,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactFailure? {
        let leafPath = selection.leafPath
        let descriptor: Int32
        switch hooks.perform(.openLeaf, .open, path: leafPath, {
            leafPath.withCString {
                Darwin.open($0, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            }
        }) {
        case let .failure(failure):
            return switch failure.code {
            case ELOOP, ENOENT, ENOTDIR: .namespaceChanged
            default: .destinationUnreadable(code: failure.code)
            }
        case let .success(value):
            descriptor = value
        }
        defer { Darwin.close(descriptor) }

        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              opened.exportFileType == S_IFREG,
              WorkspaceFileSystemIdentity(exportStatus: opened) == identity
        else {
            return .namespaceChanged
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        switch hooks.perform(.openLeaf, .getPath, path: leafPath, {
            Darwin.fcntl(descriptor, F_GETPATH, &buffer)
        }) {
        case let .failure(failure):
            return .destinationUnreadable(code: failure.code)
        case .success:
            break
        }
        let kernelPath = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard kernelPath.elementsEqual(leafPath.utf8) else {
            return .destinationAlias
        }
        return nil
    }

    /// D5 step 1: the destination volume must advertise both exclusive and swap renaming, read
    /// from the existing leaf for an overwrite and from the parent URL for a new leaf.
    static func volumeCapabilityFailure(
        _ selection: ExportArtifactSelection,
        proof: ExportArtifactLeafProof,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactFailure? {
        let url = proof.state == .missing ? selection.parentURL : selection.leafURL
        guard let capabilities = hooks.capabilities(at: url),
              capabilities.exclusiveRename,
              capabilities.exchangeRename
        else {
            return .unsupportedVolumeSemantics
        }
        return nil
    }

    /// Matches the owner's disposition with the observed leaf at panel-inspection time.
    static func approvedState(
        for disposition: ExportArtifactDisposition,
        observed: WorkspaceNoFollowFileTargetState
    ) -> Result<WorkspaceNoFollowFileTargetState, ExportArtifactFailure> {
        switch (disposition, observed) {
        case (.createNew, .missing):
            .success(.missing)
        case (.createNew, .regular):
            .failure(.destinationAlreadyExists)
        case let (.replaceConfirmed(approved), .regular(current)) where approved == current:
            .success(.regular(approved))
        case (.replaceConfirmed, .regular):
            .failure(.destinationIdentityChanged)
        case (.replaceConfirmed, .missing):
            .failure(.destinationMissing)
        }
    }

    /// Repeats the full leaf proof immediately before publication: the parent path must still
    /// name the same directory and the leaf must still hold the approved state.
    static func reproveLeaf(
        _ selection: ExportArtifactSelection,
        approved: WorkspaceNoFollowFileTargetState,
        parentIdentity: WorkspaceFileSystemIdentity,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactFailure? {
        hooks.beforeStep?(.reproveLeaf)
        if hooks.injectedFailure?(.reproveLeaf) != nil {
            return .namespaceChanged
        }
        switch proveLeaf(selection, hooks: hooks) {
        case let .failure(failure):
            return failure
        case let .success(proof):
            guard proof.parentIdentity == parentIdentity else { return .namespaceChanged }
            return proof.state == approved ? nil : .destinationIdentityChanged
        }
    }
}
