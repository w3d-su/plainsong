#if DEBUG
    import Darwin
    import Foundation

    /// An advisory lock and inode identity retained for a fixture's full app lifetime.
    ///
    /// A stale sweep can reclaim a crashed run after Darwin closes its descriptor, while
    /// a live or paused run keeps the nonblocking exclusive lock and is never age-deleted.
    final class DebugEditorFindFixtureLease {
        struct WorkspaceBinding: Codable, Equatable {
            private let formatVersion: Int
            private let workspaceDevice: UInt64
            private let workspaceInode: UInt64
            private let ownershipMarkerName: String
            private let ownershipMarkerDevice: UInt64
            private let ownershipMarkerInode: UInt64

            init(
                workspaceIdentity: DebugEditorFindFixture.EntryIdentity,
                ownershipMarkerName: String,
                ownershipMarkerIdentity: DebugEditorFindFixture.EntryIdentity
            ) {
                formatVersion = 1
                workspaceDevice = UInt64(
                    truncatingIfNeeded: workspaceIdentity.device
                )
                workspaceInode = UInt64(
                    truncatingIfNeeded: workspaceIdentity.inode
                )
                self.ownershipMarkerName = ownershipMarkerName
                ownershipMarkerDevice = UInt64(
                    truncatingIfNeeded: ownershipMarkerIdentity.device
                )
                ownershipMarkerInode = UInt64(
                    truncatingIfNeeded: ownershipMarkerIdentity.inode
                )
            }

            func matchesWorkspace(at workspaceURL: URL) throws -> Bool {
                guard formatVersion == 1,
                      isSafeOwnershipMarkerName,
                      let workspaceStatus =
                      try DebugEditorFindFixture.entryStatus(at: workspaceURL),
                      DebugEditorFindFixture.fileType(of: workspaceStatus)
                      == mode_t(S_IFDIR),
                      workspaceDevice == UInt64(
                          truncatingIfNeeded: workspaceStatus.st_dev
                      ),
                      workspaceInode == UInt64(
                          truncatingIfNeeded: workspaceStatus.st_ino
                      )
                else {
                    return false
                }
                let markerURL = workspaceURL.appendingPathComponent(
                    ownershipMarkerName,
                    isDirectory: false
                )
                guard let markerStatus =
                    try DebugEditorFindFixture.entryStatus(at: markerURL),
                    DebugEditorFindFixture.fileType(of: markerStatus)
                    == mode_t(S_IFREG)
                else {
                    return false
                }
                return ownershipMarkerDevice == UInt64(
                    truncatingIfNeeded: markerStatus.st_dev
                )
                    && ownershipMarkerInode == UInt64(
                        truncatingIfNeeded: markerStatus.st_ino
                    )
            }

            private var isSafeOwnershipMarkerName: Bool {
                let safeScalars = ownershipMarkerName.unicodeScalars.filter { scalar in
                    CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "-"
                        || scalar == "_"
                        || scalar == "."
                }
                return ownershipMarkerName.hasPrefix(
                    DebugEditorFindFixture.ownershipMarkerFilePrefix
                )
                    && ownershipMarkerName.count <= 128
                    && String(String.UnicodeScalarView(safeScalars))
                    == ownershipMarkerName
            }
        }

        private static let maximumWorkspaceBindingByteCount = 4096
        private let descriptor: Int32
        private let leaseURL: URL
        private let leaseIdentity: DebugEditorFindFixture.EntryIdentity
        private var didUnlinkPath = false
        private var isVerifiedUnlinked = false

        private init(
            descriptor: Int32,
            leaseURL: URL,
            leaseIdentity: DebugEditorFindFixture.EntryIdentity
        ) {
            self.descriptor = descriptor
            self.leaseURL = leaseURL
            self.leaseIdentity = leaseIdentity
        }

        deinit {
            close(descriptor)
        }

        static func create(at leaseURL: URL) throws -> DebugEditorFindFixtureLease {
            let descriptor = leaseURL.path.withCString { path in
                open(
                    path,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard descriptor >= 0 else {
                throw DebugEditorFindFixture.FixtureError.couldNotCreateLease(errno)
            }
            do {
                let identity = try validateDescriptor(
                    descriptor,
                    matches: leaseURL
                )
                let lockResult = flock(descriptor, LOCK_EX | LOCK_NB)
                guard lockResult == 0 else {
                    throw DebugEditorFindFixture.FixtureError.couldNotLockLease(errno)
                }
                return DebugEditorFindFixtureLease(
                    descriptor: descriptor,
                    leaseURL: leaseURL,
                    leaseIdentity: identity
                )
            } catch {
                close(descriptor)
                throw error
            }
        }

        /// Returns nil when the lease is actively locked or no lease exists.
        static func tryAcquireExisting(
            at leaseURL: URL
        ) throws -> DebugEditorFindFixtureLease? {
            let descriptor = leaseURL.path.withCString { path in
                open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                let errorCode = errno
                if errorCode == ENOENT {
                    return nil
                }
                throw DebugEditorFindFixture.FixtureError.couldNotOpenLease(errorCode)
            }
            do {
                let identity = try validateDescriptor(
                    descriptor,
                    matches: leaseURL
                )
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                    let errorCode = errno
                    if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                        close(descriptor)
                        return nil
                    }
                    throw DebugEditorFindFixture.FixtureError
                        .couldNotLockLease(errorCode)
                }
                return DebugEditorFindFixtureLease(
                    descriptor: descriptor,
                    leaseURL: leaseURL,
                    leaseIdentity: identity
                )
            } catch {
                close(descriptor)
                throw error
            }
        }

        func validatePath() throws {
            guard !didUnlinkPath else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
            let currentIdentity = try Self.validateDescriptor(
                descriptor,
                matches: leaseURL
            )
            guard currentIdentity == leaseIdentity else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
        }

        func linkCount() throws -> nlink_t {
            var fileStatus = stat()
            guard fstat(descriptor, &fileStatus) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectLease(errno)
            }
            return fileStatus.st_nlink
        }

        func bindWorkspace(_ binding: WorkspaceBinding) throws {
            try validatePath()
            guard try workspaceBinding() == nil else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
            let encoded: Data
            do {
                encoded = try JSONEncoder().encode(binding)
            } catch {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
            guard !encoded.isEmpty,
                  encoded.count <= Self.maximumWorkspaceBindingByteCount
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
            guard ftruncate(descriptor, 0) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotWriteLease(errno)
            }
            let writtenCount = encoded.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }
                return pwrite(
                    descriptor,
                    baseAddress,
                    buffer.count,
                    0
                )
            }
            guard writtenCount == encoded.count else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotWriteLease(writtenCount < 0 ? errno : EIO)
            }
            guard fsync(descriptor) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotWriteLease(errno)
            }
            guard try workspaceBinding() == binding else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
        }

        func workspaceBinding() throws -> WorkspaceBinding? {
            try validatePath()
            var fileStatus = stat()
            guard fstat(descriptor, &fileStatus) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotReadLease(errno)
            }
            guard fileStatus.st_size >= 0,
                  fileStatus.st_size
                  <= off_t(Self.maximumWorkspaceBindingByteCount)
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
            let byteCount = Int(fileStatus.st_size)
            guard byteCount > 0 else {
                return nil
            }
            var encoded = Data(count: byteCount)
            let readCount = encoded.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }
                return pread(
                    descriptor,
                    baseAddress,
                    buffer.count,
                    0
                )
            }
            guard readCount == byteCount else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotReadLease(readCount < 0 ? errno : EIO)
            }
            do {
                return try JSONDecoder().decode(
                    WorkspaceBinding.self,
                    from: encoded
                )
            } catch {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
        }

        func unlinkPathIfStillOwned() throws {
            if isVerifiedUnlinked {
                return
            }
            if !didUnlinkPath {
                try validatePath()
                let result = leaseURL.path.withCString { path in
                    unlink(path)
                }
                guard result == 0 else {
                    throw DebugEditorFindFixture.FixtureError
                        .couldNotRemoveLease(errno)
                }
                didUnlinkPath = true
            }
            guard try DebugEditorFindFixture.entryMode(at: leaseURL) == nil,
                  try linkCount() == 0
            else {
                throw DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete
            }
            isVerifiedUnlinked = true
        }

        private static func validateDescriptor(
            _ descriptor: Int32,
            matches leaseURL: URL
        ) throws -> DebugEditorFindFixture.EntryIdentity {
            var descriptorStatus = stat()
            guard fstat(descriptor, &descriptorStatus) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectLease(errno)
            }
            guard DebugEditorFindFixture.fileType(of: descriptorStatus)
                == mode_t(S_IFREG),
                let pathStatus = try DebugEditorFindFixture.entryStatus(at: leaseURL),
                DebugEditorFindFixture.fileType(of: pathStatus) == mode_t(S_IFREG)
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
            let descriptorIdentity = DebugEditorFindFixture.identity(
                of: descriptorStatus
            )
            guard descriptorIdentity == DebugEditorFindFixture.identity(of: pathStatus)
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
            return descriptorIdentity
        }
    }
#endif
