import Darwin
import Foundation

extension ExportArtifactWriter {
    /// D5 step 1, with the containment rule amended by the owner decision of 2026-09-30 (E2
    /// review). Obtains Foundation's item-replacement directory for the exact panel URL and
    /// accepts it only when it:
    /// - is not the chosen folder (compared by identity before anything else touches it);
    /// - has a canonical symlink-free spelling;
    /// - is either (a) outside the chosen folder, or (b) strictly inside the injected
    ///   app-private root while the chosen folder is a proper ancestor of that root, and is never
    ///   the chosen folder's direct child;
    /// - sits on the destination's device (the existing leaf for an overwrite, the parent path
    ///   for a new leaf).
    ///
    /// Otherwise it fails closed with no copy fallback.
    static func establishStagingDirectory(
        _ selection: ExportArtifactSelection,
        preflight: ExportArtifactPreflight,
        appPrivateRoot: URL?,
        hooks: ExportArtifactWriterHooks
    ) -> Result<ExportArtifactStagingDirectory, ExportArtifactStagingRefusal> {
        // The app-private root is proven before Foundation is asked for a directory, so its
        // `create: true` cannot have created the root or any of its parents.
        let privateRoot = provenPrivateRoot(appPrivateRoot, hooks: hooks)
        guard let returnedURL = try? hooks.stagingDirectory(for: selection.destinationURL),
              let literalPath = try? WorkspaceLiteralFileURL.absolutePath(of: returnedURL)
        else {
            return .refused(.stagingDirectoryUnavailable)
        }
        let returned: ExportArtifactStagingDirectory
        switch observeReturnedDirectory(
            WorkspaceRootContainment.normalizedDirectoryPath(literalPath),
            parentIdentity: preflight.proof.parentIdentity,
            hooks: hooks
        ) {
        case let .success(value): returned = value
        case let .failure(refusal): return .failure(refusal)
        }
        guard let directory = canonicalStagingDirectory(returned, hooks: hooks) else {
            // Foundation created it: remove it (identity-checked) or report its exact path.
            return .refused(.stagingDirectoryUnavailable, removing: returned)
        }
        if let failure = containmentFailure(
            directory,
            selection: selection,
            preflight: preflight,
            privateRoot: privateRoot,
            hooks: hooks
        ) {
            return .refused(failure, removing: directory)
        }
        let destinationDevice = preflight.proof.leafStatus.map { UInt64($0.st_dev) }
            ?? preflight.proof.parentIdentity.device
        guard directory.identity.device == destinationDevice else {
            return .refused(.stagingDirectoryOnDifferentDevice, removing: directory)
        }
        return .success(directory)
    }

    /// Identity first, by metadata alone, before anything else touches the returned directory.
    /// Foundation's spelling may cross a symlink (`/var`), so only its last component is not
    /// followed here. Only proven absence (`ENOENT`) is a clean refusal; an unobservable path or
    /// a non-directory is reported by exact path, and the chosen folder itself is never removed.
    private static func observeReturnedDirectory(
        _ returnedPath: String,
        parentIdentity: WorkspaceFileSystemIdentity,
        hooks: ExportArtifactWriterHooks
    ) -> Result<ExportArtifactStagingDirectory, ExportArtifactStagingRefusal> {
        let returnedURL = WorkspaceLiteralFileURL.fileURL(path: returnedPath, isDirectory: true)
        switch hooks.noFollowStatus(returnedPath, step: .inspectStagingDirectory, flags: AT_SYMLINK_NOFOLLOW) {
        case let .failure(failure) where failure.code == ENOENT:
            return .refused(.stagingDirectoryUnavailable)
        case .failure:
            return .refused(.stagingDirectoryUnavailable, reporting: returnedURL)
        case let .success(status) where status.exportFileType != S_IFDIR:
            return .refused(.stagingDirectoryUnavailable, reporting: returnedURL)
        case let .success(status) where WorkspaceFileSystemIdentity(exportStatus: status) == parentIdentity:
            return .refused(.stagingDirectoryInsideDestinationFolder)
        case let .success(status):
            return .success(ExportArtifactStagingDirectory(
                path: returnedPath,
                identity: WorkspaceFileSystemIdentity(exportStatus: status)
            ))
        }
    }

    /// The kernel's spelling from one `getattrlist` observation (never an open) that must report
    /// the same directory identity; that spelling must then name the same directory under
    /// `AT_SYMLINK_NOFOLLOW_ANY`, so every later staged-path call may refuse symlinks.
    private static func canonicalStagingDirectory(
        _ returned: ExportArtifactStagingDirectory,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactStagingDirectory? {
        guard case let .success(attributes) = hooks.pathAttributes(
            returned.path,
            step: .canonicalizeStagingDirectory,
            options: FSOPT_NOFOLLOW
        ),
            attributes.isDirectory,
            attributes.identity == returned.identity,
            let spelling = String(bytes: attributes.path, encoding: .utf8)
        else {
            return nil
        }
        let canonicalPath = WorkspaceRootContainment.normalizedDirectoryPath(spelling)
        guard case let .success(status) = hooks.noFollowStatus(canonicalPath, step: .inspectStagingDirectory),
              status.exportFileType == S_IFDIR,
              WorkspaceFileSystemIdentity(exportStatus: status) == returned.identity
        else {
            return nil
        }
        return ExportArtifactStagingDirectory(path: canonicalPath, identity: returned.identity)
    }

    /// A direct child of the chosen folder (Foundation's "(A Document Being Saved By …)"
    /// fallback) is always refused. A directory elsewhere under the chosen folder is accepted
    /// only below the app-private root, which was proven to exist before staging began, so the
    /// chosen folder never gains a new visible entry. Every spelling compared here is canonical:
    /// the parent path by the leaf proof, the staging directory and the root by `getattrlist`.
    private static func containmentFailure(
        _ directory: ExportArtifactStagingDirectory,
        selection: ExportArtifactSelection,
        preflight: ExportArtifactPreflight,
        privateRoot: String?,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactFailure? {
        switch hooks.noFollowStatus("\(directory.path)/..", step: .inspectStagingDirectory) {
        case let .success(status)
            where WorkspaceFileSystemIdentity(exportStatus: status) == preflight.proof.parentIdentity:
            return .stagingDirectoryInsideDestinationFolder
        case .success:
            break
        case .failure:
            return .stagingDirectoryUnavailable
        }
        guard pathLies(
            directory.path,
            inside: selection.parentPath,
            caseSensitive: preflight.inspection.volumeIsCaseSensitive
        ) else {
            return nil
        }
        guard let root = privateRoot,
              pathLiesStrictly(directory.path, inside: root),
              pathLiesStrictly(root, inside: selection.parentPath)
        else {
            return .stagingDirectoryInsideDestinationFolder
        }
        return nil
    }

    /// The app-private root's canonical spelling, proven before any staging directory exists.
    /// The root must already be a directory reached with no symlink anywhere, the final
    /// component included (`AT_SYMLINK_NOFOLLOW_ANY`; `FSOPT_NOFOLLOW_ANY` alone reports a
    /// final-component symlink as itself), and one `getattrlist` observation must report that
    /// same directory identity with its kernel spelling. If the root is missing, is not a
    /// directory, or cannot be proven, there is no root and only rule (a) applies.
    private static func provenPrivateRoot(
        _ root: URL?,
        hooks: ExportArtifactWriterHooks
    ) -> String? {
        guard let root, let literalPath = try? WorkspaceLiteralFileURL.absolutePath(of: root) else {
            return nil
        }
        let rootPath = WorkspaceRootContainment.normalizedDirectoryPath(literalPath)
        guard case let .success(status) = hooks.noFollowStatus(rootPath, step: .canonicalizePrivateRoot),
              status.exportFileType == S_IFDIR,
              case let .success(attributes) = hooks.pathAttributes(
                  rootPath,
                  step: .canonicalizePrivateRoot,
                  options: FSOPT_NOFOLLOW_ANY
              ),
              attributes.isDirectory,
              attributes.identity == WorkspaceFileSystemIdentity(exportStatus: status),
              let spelling = String(bytes: attributes.path, encoding: .utf8)
        else {
            return nil
        }
        return WorkspaceRootContainment.normalizedDirectoryPath(spelling)
    }

    /// Component-bounded containment on NFC (and, on a case-insensitive volume, case-folded)
    /// spellings: the identity checks catch Foundation's sibling fallback; this catches deeper
    /// nesting under the chosen folder. A path equal to `directory` also counts as inside.
    static func pathLies(_ path: String, inside directory: String, caseSensitive: Bool) -> Bool {
        func key(_ component: Substring) -> String {
            let normalized = String(component).precomposedStringWithCanonicalMapping
            guard !caseSensitive else { return normalized }
            return normalized
                .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping
        }
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: true).map(key)
        let directoryComponents = directory.split(separator: "/", omittingEmptySubsequences: true).map(key)
        guard pathComponents.count >= directoryComponents.count else { return false }
        return zip(pathComponents, directoryComponents).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    /// Strict, byte-exact, component-wise containment of two canonical spellings. It is used
    /// only to accept staging, so it never folds case or normalization.
    static func pathLiesStrictly(_ path: String, inside ancestor: String) -> Bool {
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: true)
        let ancestorComponents = ancestor.split(separator: "/", omittingEmptySubsequences: true)
        guard pathComponents.count > ancestorComponents.count else { return false }
        return zip(pathComponents, ancestorComponents).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    /// Removes the item-replacement directory only while its path names the same (empty)
    /// directory, and proves it absent. `unlinkat(AT_REMOVEDIR | AT_SYMLINK_NOFOLLOW_ANY)` never
    /// removes a non-empty directory and never follows a symlinked component.
    static func removeStagingDirectory(
        _ directory: ExportArtifactStagingDirectory,
        hooks: ExportArtifactWriterHooks
    ) -> Bool {
        switch hooks.noFollowStatus(directory.path, step: .proveRemoved) {
        case let .failure(failure):
            return failure.code == ENOENT
        case let .success(status):
            guard status.exportFileType == S_IFDIR,
                  WorkspaceFileSystemIdentity(exportStatus: status) == directory.identity
            else {
                return false
            }
        }
        let path = directory.path
        guard case .success = hooks.perform(.removeStagingDirectory, .rmdir, path: path, {
            path.withCString { Darwin.unlinkat(AT_FDCWD, $0, AT_REMOVEDIR | AT_SYMLINK_NOFOLLOW_ANY) }
        }) else {
            return false
        }
        if case let .failure(failure) = hooks.noFollowStatus(path, step: .proveRemoved) {
            return failure.code == ENOENT
        }
        return false
    }
}

extension Result where Success == ExportArtifactStagingDirectory, Failure == ExportArtifactStagingRefusal {
    static func refused(
        _ failure: ExportArtifactFailure,
        removing directory: ExportArtifactStagingDirectory? = nil,
        reporting reportedURL: URL? = nil
    ) -> Self {
        .failure(ExportArtifactStagingRefusal(
            failure: failure,
            removableDirectory: directory,
            reportedURL: reportedURL
        ))
    }
}
