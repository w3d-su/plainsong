#if DEBUG
    import Darwin
    import Foundation

    /// An advisory lock and inode identity retained for a fixture's full app lifetime.
    ///
    /// A stale sweep can reclaim a crashed run after Darwin closes its descriptor, while
    /// a live or paused run keeps the nonblocking exclusive lock and is never age-deleted.
    final class DebugEditorFindFixtureLease {
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
