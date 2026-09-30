import Darwin
import Foundation

struct ExportArtifactVolumeCapabilities: Equatable, Sendable {
    let exclusiveRename: Bool
    let exchangeRename: Bool
}

/// Named filesystem boundaries of one export operation. Tests inject an `errno` at a boundary
/// (the real call is skipped and fails with it) or run a race immediately before it.
enum ExportArtifactWriterStep: Hashable, Sendable {
    case inspectParent
    case inspectLeaf
    case openLeaf
    case inspectStagingDirectory
    case createStaged
    case writeStaged
    case chmodStaged
    case syncStaged
    /// Immediately before the pre-publication leaf re-proof.
    case reproveLeaf
    case coordinate
    case publish
    case postflight
    case twoNameProof
    case reverseSwap
    case reversalProof
    case unlinkDisplaced
    case unlinkStaged
    case removeStagingDirectory
    /// No-follow observations that prove a staged name or the directory removed, or classify
    /// a residue. An injected failure leaves removal unproven.
    case proveRemoved
}

/// One path-based filesystem call, recorded so tests can prove exactly what the writer touched.
struct ExportArtifactWriterCall: Equatable, Sendable {
    enum Operation: Equatable, Sendable {
        case fstatat
        case open
        case getPath
        case write
        case fchmod
        case fsync
        case rename
        case unlink
        case rmdir
        case coordinate
    }

    let step: ExportArtifactWriterStep
    let operation: Operation
    let path: String
}

struct ExportArtifactSyscallFailure: Error, Equatable {
    let code: Int32
}

/// Test seams. Production uses Foundation's item-replacement directory, the real volume keys and
/// ubiquity, and no observer or injection.
struct ExportArtifactWriterHooks: Sendable {
    static let production = ExportArtifactWriterHooks()

    /// Returns the item-replacement directory for the exact panel URL.
    let itemReplacementDirectory: (@Sendable (URL) throws -> URL)?
    let volumeCapabilities: (@Sendable (URL) -> ExportArtifactVolumeCapabilities?)?
    let isUbiquitous: (@Sendable (URL) -> Bool)?
    let observer: (@Sendable (ExportArtifactWriterCall) -> Void)?
    let beforeStep: (@Sendable (ExportArtifactWriterStep) -> Void)?
    let injectedFailure: (@Sendable (ExportArtifactWriterStep) -> Int32?)?
    let afterPreflight: (@Sendable () -> Void)?
    let afterPublication: (@Sendable () -> Void)?

    init(
        itemReplacementDirectory: (@Sendable (URL) throws -> URL)? = nil,
        volumeCapabilities: (@Sendable (URL) -> ExportArtifactVolumeCapabilities?)? = nil,
        isUbiquitous: (@Sendable (URL) -> Bool)? = nil,
        observer: (@Sendable (ExportArtifactWriterCall) -> Void)? = nil,
        beforeStep: (@Sendable (ExportArtifactWriterStep) -> Void)? = nil,
        injectedFailure: (@Sendable (ExportArtifactWriterStep) -> Int32?)? = nil,
        afterPreflight: (@Sendable () -> Void)? = nil,
        afterPublication: (@Sendable () -> Void)? = nil
    ) {
        self.itemReplacementDirectory = itemReplacementDirectory
        self.volumeCapabilities = volumeCapabilities
        self.isUbiquitous = isUbiquitous
        self.observer = observer
        self.beforeStep = beforeStep
        self.injectedFailure = injectedFailure
        self.afterPreflight = afterPreflight
        self.afterPublication = afterPublication
    }

    /// Runs one boundary: records the call, runs any test race, then either fails with an
    /// injected `errno` or performs the call. `body` returns the raw syscall result; a negative
    /// result is a failure whose `errno` is read immediately.
    func perform(
        _ step: ExportArtifactWriterStep,
        _ operation: ExportArtifactWriterCall.Operation,
        path: String,
        _ body: () -> Int32
    ) -> Result<Int32, ExportArtifactSyscallFailure> {
        observer?(ExportArtifactWriterCall(step: step, operation: operation, path: path))
        beforeStep?(step)
        if let code = injectedFailure?(step) {
            return .failure(ExportArtifactSyscallFailure(code: code))
        }
        let result = body()
        let code = errno
        guard result >= 0 else {
            return .failure(ExportArtifactSyscallFailure(code: code == 0 ? EIO : code))
        }
        return .success(result)
    }

    /// `fstatat(AT_FDCWD, path, …, AT_SYMLINK_NOFOLLOW_ANY)`: no component may be a symlink,
    /// and a symlink leaf is reported as itself.
    func noFollowStatus(
        _ path: String,
        step: ExportArtifactWriterStep
    ) -> Result<stat, ExportArtifactSyscallFailure> {
        var status = stat()
        return perform(step, .fstatat, path: path) {
            path.withCString { Darwin.fstatat(AT_FDCWD, $0, &status, AT_SYMLINK_NOFOLLOW_ANY) }
        }.map { _ in status }
    }

    func stagingDirectory(for destinationURL: URL) throws -> URL {
        if let itemReplacementDirectory {
            return try itemReplacementDirectory(destinationURL)
        }
        return try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationURL,
            create: true
        )
    }

    /// Volume keys read from a fresh literal URL, so no cached resource value is reused.
    func capabilities(at url: URL) -> ExportArtifactVolumeCapabilities? {
        if let volumeCapabilities {
            return volumeCapabilities(url)
        }
        guard let values = try? url.resourceValues(forKeys: [
            .volumeSupportsExclusiveRenamingKey,
            .volumeSupportsSwapRenamingKey,
        ]) else {
            return nil
        }
        return ExportArtifactVolumeCapabilities(
            exclusiveRename: values.volumeSupportsExclusiveRenaming == true,
            exchangeRename: values.volumeSupportsSwapRenaming == true
        )
    }

    func ubiquitous(_ url: URL) -> Bool {
        if let isUbiquitous {
            return isUbiquitous(url)
        }
        return FileManager.default.isUbiquitousItem(at: url)
    }
}

extension WorkspaceFileSystemIdentity {
    init(exportStatus status: stat) {
        self.init(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }
}

extension stat {
    var exportFileType: mode_t {
        st_mode & S_IFMT
    }
}
