import Darwin
import Foundation

/// The operation-private item-replacement directory, by its canonical symlink-free path.
struct ExportArtifactStagingDirectory {
    let path: String
    let identity: WorkspaceFileSystemIdentity

    var url: URL {
        WorkspaceLiteralFileURL.fileURL(path: path, isDirectory: true)
    }
}

/// The single staged file inside the item-replacement directory, written and synced.
struct ExportArtifactStagedFile {
    let path: String
    let identity: WorkspaceFileSystemIdentity
    let byteCount: Int64

    var url: URL {
        WorkspaceLiteralFileURL.fileURL(path: path, isDirectory: false)
    }
}

/// Staging could not be established. `removableDirectory` is an item-replacement directory the
/// writer must still remove (only while empty and identity-matched) or report.
struct ExportArtifactStagingRefusal: Error {
    let failure: ExportArtifactFailure
    let removableDirectory: ExportArtifactStagingDirectory?
}

/// What a failed staged-file preparation left behind.
enum ExportArtifactStagedEntry {
    case none
    case file(ExportArtifactStagedFile)
    /// The exclusive create succeeded but its identity could not be sampled.
    case unproven(path: String)
}

struct ExportArtifactStagingFailure: Error {
    let failure: ExportArtifactFailure
    let entry: ExportArtifactStagedEntry
}

/// Labels a re-observed entry by exact identity: the panel-approved displaced original (a
/// replacement only) or the writer's staged bytes.
struct ExportArtifactResidueClassifier {
    let approvedIdentity: WorkspaceFileSystemIdentity?
    let writerIdentity: WorkspaceFileSystemIdentity?

    func contents(of identity: WorkspaceFileSystemIdentity) -> ExportArtifactResidueContents {
        if identity == approvedIdentity {
            return .displacedOriginal
        }
        if identity == writerIdentity {
            return .writerBytes
        }
        return .unknown
    }

    func residue(_ url: URL, status: stat) -> ExportArtifactResidue {
        guard status.exportFileType == S_IFREG else { return .retained(url, holding: .unknown) }
        return .retained(url, holding: contents(of: WorkspaceFileSystemIdentity(exportStatus: status)))
    }
}

extension ExportArtifactWriter {
    /// D5 step 1. Obtains Foundation's item-replacement directory for the exact panel URL,
    /// resolves its canonical symlink-free spelling, and fails closed when it is unavailable,
    /// is (or lies inside) the chosen folder, or sits on a different device than the destination
    /// (the existing leaf for an overwrite, the parent path for a new leaf). No copy fallback.
    static func establishStagingDirectory(
        _ selection: ExportArtifactSelection,
        preflight: ExportArtifactPreflight,
        hooks: ExportArtifactWriterHooks
    ) -> Result<ExportArtifactStagingDirectory, ExportArtifactStagingRefusal> {
        func refuse(
            _ failure: ExportArtifactFailure,
            removing directory: ExportArtifactStagingDirectory? = nil
        ) -> Result<ExportArtifactStagingDirectory, ExportArtifactStagingRefusal> {
            .failure(ExportArtifactStagingRefusal(failure: failure, removableDirectory: directory))
        }
        guard let returnedURL = try? hooks.stagingDirectory(for: selection.destinationURL),
              let returnedPath = try? WorkspaceLiteralFileURL.absolutePath(of: returnedURL),
              let directory = canonicalStagingDirectory(returnedPath, hooks: hooks)
        else {
            return refuse(.stagingDirectoryUnavailable)
        }
        let parentIdentity = preflight.proof.parentIdentity
        guard directory.identity != parentIdentity else {
            // Never remove the user's chosen folder.
            return refuse(.stagingDirectoryInsideDestinationFolder)
        }
        switch hooks.noFollowStatus("\(directory.path)/..", step: .inspectStagingDirectory) {
        case let .success(status) where WorkspaceFileSystemIdentity(exportStatus: status) == parentIdentity:
            return refuse(.stagingDirectoryInsideDestinationFolder, removing: directory)
        case .success:
            break
        case .failure:
            return refuse(.stagingDirectoryUnavailable, removing: directory)
        }
        if pathLies(
            directory.path,
            inside: selection.parentPath,
            caseSensitive: preflight.inspection.volumeIsCaseSensitive
        ) {
            return refuse(.stagingDirectoryInsideDestinationFolder, removing: directory)
        }
        let destinationDevice = preflight.proof.leafStatus.map { UInt64($0.st_dev) } ?? parentIdentity.device
        guard directory.identity.device == destinationDevice else {
            return refuse(.stagingDirectoryOnDifferentDevice, removing: directory)
        }
        return .success(directory)
    }

    /// Opens the returned directory (never the chosen folder) only to read its kernel path, then
    /// requires that symlink-free spelling to name the same directory under
    /// `AT_SYMLINK_NOFOLLOW_ANY`, so every later staged-path call may refuse symlinks.
    private static func canonicalStagingDirectory(
        _ returnedPath: String,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactStagingDirectory? {
        guard case let .success(descriptor) = hooks.perform(
            .inspectStagingDirectory,
            .open,
            path: returnedPath,
            { returnedPath.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } }
        ) else {
            return nil
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fstat(descriptor, &opened) == 0,
              opened.exportFileType == S_IFDIR,
              Darwin.fcntl(descriptor, F_GETPATH, &buffer) != -1
        else {
            return nil
        }
        let canonicalPath = WorkspaceRootContainment.normalizedDirectoryPath(String(cString: buffer))
        let identity = WorkspaceFileSystemIdentity(exportStatus: opened)
        guard case let .success(status) = hooks.noFollowStatus(canonicalPath, step: .inspectStagingDirectory),
              status.exportFileType == S_IFDIR,
              WorkspaceFileSystemIdentity(exportStatus: status) == identity
        else {
            return nil
        }
        return ExportArtifactStagingDirectory(path: canonicalPath, identity: identity)
    }

    /// Component-bounded containment on NFC (and, on a case-insensitive volume, case-folded)
    /// spellings: the identity checks catch Foundation's sibling fallback; this catches deeper
    /// nesting under the chosen folder.
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

    /// D5 step 2 and Q3. Exactly one staged file: `open(O_CREAT | O_EXCL | O_NOFOLLOW_ANY |
    /// O_WRONLY)` with mode `0666` (so a new leaf gets `0666 & ~umask`), the complete bytes, the
    /// displaced file's permission bits for a confirmed overwrite, then `fsync`. `O_NOFOLLOW_ANY`
    /// subsumes D5's `O_NOFOLLOW` (the kernel rejects the two together with `EINVAL`).
    static func createStagedFile(
        _ bytes: Data,
        in directory: ExportArtifactStagingDirectory,
        displacedMode: mode_t?,
        hooks: ExportArtifactWriterHooks
    ) -> Result<ExportArtifactStagedFile, ExportArtifactStagingFailure> {
        let path = "\(directory.path)/plainsong-export-\(UUID().uuidString).tmp"
        let descriptor: Int32
        switch hooks.perform(.createStaged, .open, path: path, {
            path.withCString {
                Darwin.open($0, O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_WRONLY | O_CLOEXEC, 0o666)
            }
        }) {
        case let .failure(failure):
            let code = failure.code
            let refusal: ExportArtifactFailure = code == EPERM || code == EACCES
                ? .stagingNotPermitted(code: code)
                : .stagingUnavailable(code: code)
            return .failure(ExportArtifactStagingFailure(failure: refusal, entry: .none))
        case let .success(value):
            descriptor = value
        }
        defer { Darwin.close(descriptor) }
        var created = stat()
        guard Darwin.fstat(descriptor, &created) == 0 else {
            return .failure(ExportArtifactStagingFailure(
                failure: .stagingUnavailable(code: errno),
                entry: .unproven(path: path)
            ))
        }
        let staged = ExportArtifactStagedFile(
            path: path,
            identity: WorkspaceFileSystemIdentity(exportStatus: created),
            byteCount: Int64(bytes.count)
        )
        if let failure = fillStagedFile(
            staged,
            bytes: bytes,
            descriptor: descriptor,
            displacedMode: displacedMode,
            hooks: hooks
        ) {
            return .failure(ExportArtifactStagingFailure(failure: failure, entry: .file(staged)))
        }
        return .success(staged)
    }

    /// Writes the complete bytes, applies the displaced mode (overwrite only), and `fsync`s, then
    /// proves the descriptor still names the staged identity with the full byte count.
    private static func fillStagedFile(
        _ staged: ExportArtifactStagedFile,
        bytes: Data,
        descriptor: Int32,
        displacedMode: mode_t?,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactFailure? {
        let path = staged.path
        if case .failure = hooks.perform(.writeStaged, .write, path: path, { writeAll(bytes, to: descriptor) }) {
            return .writeFailed(.unreadable)
        }
        if let displacedMode,
           case .failure = hooks.perform(
               .chmodStaged,
               .fchmod,
               path: path,
               { Darwin.fchmod(descriptor, displacedMode) }
           )
        {
            return .writeFailed(.unreadable)
        }
        if case .failure = hooks.perform(.syncStaged, .fsync, path: path, { Darwin.fsync(descriptor) }) {
            return .writeFailed(.durabilityFailed)
        }
        var synced = stat()
        guard Darwin.fstat(descriptor, &synced) == 0,
              WorkspaceFileSystemIdentity(exportStatus: synced) == staged.identity,
              Int64(synced.st_size) == staged.byteCount
        else {
            return .writeFailed(.unstable)
        }
        return nil
    }

    /// Writes every byte, retrying `EINTR` and short writes. Returns `0`, or `-1` with `errno`.
    private static func writeAll(_ bytes: Data, to descriptor: Int32) -> Int32 {
        bytes.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return -1
                }
                guard count > 0 else {
                    errno = EIO
                    return -1
                }
                offset += count
            }
            return 0
        }
    }

    /// Unlinks `path` only while it still names `expected` (a regular file), then proves the name
    /// empty. Any other occupant is preserved and reported.
    static func removeEntry(
        _ path: String,
        expected: WorkspaceFileSystemIdentity,
        step: ExportArtifactWriterStep,
        classifier: ExportArtifactResidueClassifier,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactResidue {
        let url = WorkspaceLiteralFileURL.fileURL(path: path, isDirectory: false)
        switch hooks.noFollowStatus(path, step: .proveRemoved) {
        case let .failure(failure) where failure.code == ENOENT:
            return .none
        case .failure:
            return .removalIndeterminate(url)
        case let .success(status):
            let identity = WorkspaceFileSystemIdentity(exportStatus: status)
            guard status.exportFileType == S_IFREG, identity == expected else {
                return classifier.residue(url, status: status)
            }
        }
        guard case .success = hooks.perform(step, .unlink, path: path, { path.withCString { Darwin.unlink($0) } })
        else {
            return .retained(url, holding: classifier.contents(of: expected))
        }
        return observeResidue(path, classifier: classifier, hooks: hooks)
    }

    /// Re-observes one staged-name entry without following links or removing anything.
    static func observeResidue(
        _ path: String,
        classifier: ExportArtifactResidueClassifier,
        hooks: ExportArtifactWriterHooks
    ) -> ExportArtifactResidue {
        let url = WorkspaceLiteralFileURL.fileURL(path: path, isDirectory: false)
        switch hooks.noFollowStatus(path, step: .proveRemoved) {
        case let .failure(failure) where failure.code == ENOENT:
            return .none
        case .failure:
            return .removalIndeterminate(url)
        case let .success(status):
            return classifier.residue(url, status: status)
        }
    }

    /// Removes the item-replacement directory only while its path names the same (empty)
    /// directory, and proves it absent. `rmdir` never removes a non-empty directory.
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
            path.withCString { Darwin.rmdir($0) }
        }) else {
            return false
        }
        if case let .failure(failure) = hooks.noFollowStatus(path, step: .proveRemoved) {
            return failure.code == ENOENT
        }
        return false
    }
}
