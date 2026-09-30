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
        func refuse(
            _ failure: ExportArtifactFailure,
            removing directory: ExportArtifactStagingDirectory? = nil
        ) -> Result<ExportArtifactStagingDirectory, ExportArtifactStagingRefusal> {
            .failure(ExportArtifactStagingRefusal(failure: failure, removableDirectory: directory))
        }
        guard let returnedURL = try? hooks.stagingDirectory(for: selection.destinationURL),
              let literalPath = try? WorkspaceLiteralFileURL.absolutePath(of: returnedURL)
        else {
            return refuse(.stagingDirectoryUnavailable)
        }
        let returnedPath = WorkspaceRootContainment.normalizedDirectoryPath(literalPath)
        let parentIdentity = preflight.proof.parentIdentity
        // Identity first, by metadata alone, before anything else touches the returned directory.
        // Foundation's spelling may cross a symlink (`/var`), so only its last component is
        // not followed here.
        guard case let .success(status) = hooks.noFollowStatus(
            returnedPath,
            step: .inspectStagingDirectory,
            flags: AT_SYMLINK_NOFOLLOW
        ), status.exportFileType == S_IFDIR else {
            // Absent, or not a directory: nothing here that the writer may remove.
            return refuse(.stagingDirectoryUnavailable)
        }
        let identity = WorkspaceFileSystemIdentity(exportStatus: status)
        guard identity != parentIdentity else {
            // Never remove the user's chosen folder.
            return refuse(.stagingDirectoryInsideDestinationFolder)
        }
        let returned = ExportArtifactStagingDirectory(path: returnedPath, identity: identity)
        guard let directory = canonicalStagingDirectory(returned, hooks: hooks) else {
            // Foundation created it: remove it (identity-checked) or report its exact path.
            return refuse(.stagingDirectoryUnavailable, removing: returned)
        }
        if let failure = containmentFailure(
            directory,
            selection: selection,
            preflight: preflight,
            appPrivateRoot: appPrivateRoot,
            hooks: hooks
        ) {
            return refuse(failure, removing: directory)
        }
        let destinationDevice = preflight.proof.leafStatus.map { UInt64($0.st_dev) } ?? parentIdentity.device
        guard directory.identity.device == destinationDevice else {
            return refuse(.stagingDirectoryOnDifferentDevice, removing: directory)
        }
        return .success(directory)
    }

    /// The kernel's spelling from `getattrlist(ATTR_CMN_FULLPATH)` (never an open), which must
    /// name the same directory under `AT_SYMLINK_NOFOLLOW_ANY`, so every later staged-path call
    /// may refuse symlinks.
    private static func canonicalStagingDirectory(
        _ returned: ExportArtifactStagingDirectory,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactStagingDirectory? {
        guard case let .success(bytes) = hooks.fullPath(
            returned.path,
            step: .canonicalizeStagingDirectory,
            options: FSOPT_NOFOLLOW
        ), let spelling = String(bytes: bytes, encoding: .utf8), spelling.hasPrefix("/") else {
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
    /// only below pre-existing app-private directories, so the chosen folder never gains a new
    /// visible entry. Every spelling compared here is canonical: the parent path is proven
    /// canonical by the leaf proof.
    private static func containmentFailure(
        _ directory: ExportArtifactStagingDirectory,
        selection: ExportArtifactSelection,
        preflight: ExportArtifactPreflight,
        appPrivateRoot: URL?,
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
        guard let root = canonicalPrivateRoot(appPrivateRoot, hooks: hooks),
              pathLiesStrictly(directory.path, inside: root),
              pathLiesStrictly(root, inside: selection.parentPath)
        else {
            return .stagingDirectoryInsideDestinationFolder
        }
        return nil
    }

    /// The app-private root's kernel spelling (`getattrlist(ATTR_CMN_FULLPATH)` with
    /// `FSOPT_NOFOLLOW_ANY`). Any failure leaves only rule (a).
    private static func canonicalPrivateRoot(
        _ root: URL?,
        hooks: ExportArtifactWriterHooks
    ) -> String? {
        guard let root,
              let literalPath = try? WorkspaceLiteralFileURL.absolutePath(of: root),
              case let .success(bytes) = hooks.fullPath(
                  WorkspaceRootContainment.normalizedDirectoryPath(literalPath),
                  step: .canonicalizePrivateRoot,
                  options: FSOPT_NOFOLLOW_ANY
              ),
              let spelling = String(bytes: bytes, encoding: .utf8),
              spelling.hasPrefix("/")
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
