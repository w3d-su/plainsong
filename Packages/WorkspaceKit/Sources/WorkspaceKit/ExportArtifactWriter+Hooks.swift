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
    /// `getattrlist(ATTR_CMN_FULLPATH)` of the returned item-replacement directory.
    case canonicalizeStagingDirectory
    /// The combined `getattrlist` observation of a new leaf's parent (spelling, identity, type).
    case canonicalizeParent
    /// `getattrlist(ATTR_CMN_FULLPATH)` of the injected app-private root.
    case canonicalizePrivateRoot
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
        /// `getattrlist(ATTR_CMN_FULLPATH)`: metadata only, never an open.
        case fullPath
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

/// A validated `getattrlist` reply for `ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID |
/// ATTR_CMN_FULLPATH`, the same validation `descriptorReportedPath` applies to a path reply.
struct ExportArtifactPathAttributes: Equatable {
    /// The kernel spelling, without its terminating NUL.
    let path: [UInt8]
    let identity: WorkspaceFileSystemIdentity
    let isDirectory: Bool

    /// Attributes come back in bit order after the returned-length word: `dev_t` device,
    /// `fsobj_type_t` type, `u_int64_t` file ID, then the path's `attrreference_t`, whose data
    /// offset is relative to the reference itself. Loads are unaligned; every offset and length is
    /// checked against the returned length, and the path must start with `/` and end with its
    /// only NUL.
    static func parse(_ reply: UnsafeRawBufferPointer) -> ExportArtifactPathAttributes? {
        let deviceOffset = MemoryLayout<UInt32>.size
        let typeOffset = deviceOffset + MemoryLayout<dev_t>.size
        let fileIDOffset = typeOffset + MemoryLayout<fsobj_type_t>.size
        let referenceOffset = fileIDOffset + MemoryLayout<UInt64>.size
        let headerSize = referenceOffset + MemoryLayout<attrreference_t>.size
        guard reply.count >= headerSize else { return nil }
        let returnedLength = Int(reply.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        guard returnedLength >= headerSize, returnedLength <= reply.count else { return nil }
        let device = reply.loadUnaligned(fromByteOffset: deviceOffset, as: dev_t.self)
        let type = reply.loadUnaligned(fromByteOffset: typeOffset, as: fsobj_type_t.self)
        let fileID = reply.loadUnaligned(fromByteOffset: fileIDOffset, as: UInt64.self)
        let dataOffset = Int(reply.loadUnaligned(fromByteOffset: referenceOffset, as: Int32.self))
        let dataLength = Int(reply.loadUnaligned(
            fromByteOffset: referenceOffset + MemoryLayout<Int32>.size,
            as: UInt32.self
        ))
        let start = referenceOffset + dataOffset
        guard device >= 0,
              dataLength > 1,
              start >= headerSize,
              start <= returnedLength,
              dataLength <= returnedLength - start
        else {
            return nil
        }
        let bytes = reply[start ..< start + dataLength]
        guard bytes.first == UInt8(ascii: "/"), bytes.last == 0, !bytes.dropLast().contains(0) else {
            return nil
        }
        return ExportArtifactPathAttributes(
            path: Array(bytes.dropLast()),
            identity: WorkspaceFileSystemIdentity(device: UInt64(device), inode: fileID),
            isDirectory: type == fsobj_type_t(VDIR.rawValue)
        )
    }
}

/// Test seams. Production uses Foundation's item-replacement directory, the real volume keys and
/// ubiquity, and no observer or injection.
struct ExportArtifactWriterHooks: Sendable {
    static let production = ExportArtifactWriterHooks()

    /// Returns the item-replacement directory for the exact panel URL.
    let itemReplacementDirectory: (@Sendable (URL) throws -> URL)?
    let volumeCapabilities: (@Sendable (URL) -> ExportArtifactVolumeCapabilities?)?
    let isUbiquitous: (@Sendable (URL) -> Bool)?
    /// Supplies the coordinator for a ubiquitous destination, so a test can cancel a real one.
    let fileCoordinator: (@Sendable () -> NSFileCoordinator)?
    let observer: (@Sendable (ExportArtifactWriterCall) -> Void)?
    let beforeStep: (@Sendable (ExportArtifactWriterStep) -> Void)?
    let injectedFailure: (@Sendable (ExportArtifactWriterStep) -> Int32?)?
    let afterPreflight: (@Sendable () -> Void)?
    let afterPublication: (@Sendable () -> Void)?

    init(
        itemReplacementDirectory: (@Sendable (URL) throws -> URL)? = nil,
        volumeCapabilities: (@Sendable (URL) -> ExportArtifactVolumeCapabilities?)? = nil,
        isUbiquitous: (@Sendable (URL) -> Bool)? = nil,
        fileCoordinator: (@Sendable () -> NSFileCoordinator)? = nil,
        observer: (@Sendable (ExportArtifactWriterCall) -> Void)? = nil,
        beforeStep: (@Sendable (ExportArtifactWriterStep) -> Void)? = nil,
        injectedFailure: (@Sendable (ExportArtifactWriterStep) -> Int32?)? = nil,
        afterPreflight: (@Sendable () -> Void)? = nil,
        afterPublication: (@Sendable () -> Void)? = nil
    ) {
        self.itemReplacementDirectory = itemReplacementDirectory
        self.volumeCapabilities = volumeCapabilities
        self.isUbiquitous = isUbiquitous
        self.fileCoordinator = fileCoordinator
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
    /// and a symlink leaf is reported as itself. `AT_SYMLINK_NOFOLLOW` is used only for the
    /// item-replacement directory spelling Foundation returned.
    func noFollowStatus(
        _ path: String,
        step: ExportArtifactWriterStep,
        flags: Int32 = AT_SYMLINK_NOFOLLOW_ANY
    ) -> Result<stat, ExportArtifactSyscallFailure> {
        var status = stat()
        return perform(step, .fstatat, path: path) {
            path.withCString { Darwin.fstatat(AT_FDCWD, $0, &status, flags) }
        }.map { _ in status }
    }

    /// One `getattrlist` observation of an existing entry: its kernel-canonical spelling
    /// (`ATTR_CMN_FULLPATH`) together with its identity (`ATTR_CMN_DEVID`, `ATTR_CMN_FILEID`) and
    /// type (`ATTR_CMN_OBJTYPE`), so the spelling can never belong to a different object than the
    /// identity checked beside it. This is a metadata read: it never opens the entry, so it works
    /// on a directory the process may search but not read (a leaf-only grant's parent).
    func pathAttributes(
        _ path: String,
        step: ExportArtifactWriterStep,
        options: Int32
    ) -> Result<ExportArtifactPathAttributes, ExportArtifactSyscallFailure> {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FILEID) | attrgroup_t(ATTR_CMN_FULLPATH)
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) + 64)
        return perform(step, .fullPath, path: path) {
            buffer.withUnsafeMutableBytes { raw in
                path.withCString { Darwin.getattrlist($0, &request, raw.baseAddress, raw.count, UInt32(options)) }
            }
        }.flatMap { _ in
            buffer.withUnsafeBytes(ExportArtifactPathAttributes.parse)
                .map { .success($0) } ?? .failure(ExportArtifactSyscallFailure(code: EIO))
        }
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

    func makeFileCoordinator() -> NSFileCoordinator {
        fileCoordinator?() ?? NSFileCoordinator(filePresenter: nil)
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
