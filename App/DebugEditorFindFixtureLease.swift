#if DEBUG
    import Darwin
    import Foundation

    struct EditorFindFixtureWorkspaceIdentity {
        let workspace: DebugEditorFindFixture.EntryIdentity
        let ownershipMarkerName: String
        let ownershipMarker: DebugEditorFindFixture.EntryIdentity
    }

    /// An advisory lock and inode identity retained for a fixture's full app lifetime.
    ///
    /// A stale sweep can reclaim a crashed run after Darwin closes its descriptor, while
    /// a live or paused run keeps the nonblocking exclusive lock and is never age-deleted.
    final class DebugEditorFindFixtureLease {
        private static let maximumWorkspaceBindingByteCount = 4096
        private let descriptor: Int32
        private let leaseURL: URL
        private let leaseIdentity: DebugEditorFindFixture.EntryIdentity
        private let rootHandle: DebugEditorFindFixtureRootHandle
        private var quarantineURL: URL?
        private var unlinkAttemptStarted = false
        private var didUnlinkPath = false
        private var isVerifiedUnlinked = false

        private init(
            descriptor: Int32,
            leaseURL: URL,
            leaseIdentity: DebugEditorFindFixture.EntryIdentity,
            rootHandle: DebugEditorFindFixtureRootHandle,
            quarantineURL: URL? = nil
        ) {
            self.descriptor = descriptor
            self.leaseURL = leaseURL
            self.leaseIdentity = leaseIdentity
            self.rootHandle = rootHandle
            self.quarantineURL = quarantineURL
        }

        deinit {
            close(descriptor)
        }
    }

    extension DebugEditorFindFixtureLease {
        static func create(
            at leaseURL: URL,
            rootHandle suppliedRootHandle: DebugEditorFindFixtureRootHandle? = nil
        ) throws -> DebugEditorFindFixtureLease {
            let rootHandle = try suppliedRootHandle
                ?? makeRootHandle(for: leaseURL)
            let descriptor = try rootHandle.createRegularFile(at: leaseURL)
            do {
                let identity = try validateDescriptor(
                    descriptor,
                    matches: leaseURL,
                    rootHandle: rootHandle
                )
                let lockResult = flock(descriptor, LOCK_EX | LOCK_NB)
                guard lockResult == 0 else {
                    throw DebugEditorFindFixture.FixtureError.couldNotLockLease(errno)
                }
                return DebugEditorFindFixtureLease(
                    descriptor: descriptor,
                    leaseURL: leaseURL,
                    leaseIdentity: identity,
                    rootHandle: rootHandle
                )
            } catch {
                close(descriptor)
                throw error
            }
        }

        /// Returns nil when the lease is actively locked or no lease exists.
        static func tryAcquireExisting(
            at leaseURL: URL,
            publishedLeaseURL: URL? = nil,
            expectedIdentity: DebugEditorFindFixture.EntryIdentity? = nil,
            rootHandle suppliedRootHandle: DebugEditorFindFixtureRootHandle? = nil
        ) throws -> DebugEditorFindFixtureLease? {
            let publishedLeaseURL = publishedLeaseURL ?? leaseURL
            let rootHandle = try suppliedRootHandle
                ?? makeRootHandle(for: leaseURL)
            guard let descriptor = try rootHandle.openRegularFile(at: leaseURL)
            else { return nil }
            do {
                let identity = try validateDescriptor(
                    descriptor,
                    matches: leaseURL,
                    rootHandle: rootHandle
                )
                guard expectedIdentity == nil || identity == expectedIdentity else {
                    throw DebugEditorFindFixture.FixtureError.unsafeLease
                }
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
                    leaseURL: publishedLeaseURL,
                    leaseIdentity: identity,
                    rootHandle: rootHandle,
                    quarantineURL:
                    publishedLeaseURL == leaseURL ? nil : leaseURL
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
            let currentLeaseURL = quarantineURL ?? leaseURL
            let currentIdentity = try Self.validateDescriptor(
                descriptor,
                matches: currentLeaseURL,
                rootHandle: rootHandle
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

        func unlinkPathIfStillOwned(
            cleanupBoundaryHandler:
            EditorFindFixtureCleanupHandler? = nil
        ) throws {
            if isVerifiedUnlinked {
                return
            }
            try reconcileRecordedMutation()
            if !didUnlinkPath {
                if quarantineURL == nil {
                    try validatePath()
                    let destination = try DebugEditorFindFixture
                        .makeLeaseQuarantineURL(for: leaseURL)
                    quarantineURL = destination
                    try cleanupBoundaryHandler?(
                        .willQuarantineLease(
                            source: leaseURL,
                            destination: destination
                        )
                    )
                    try rootHandle.quarantine(
                        source: leaseURL,
                        destination: destination,
                        afterRename: {
                            try cleanupBoundaryHandler?(
                                .didRenameLeaseQuarantine(
                                    source: self.leaseURL,
                                    destination: destination
                                )
                            )
                        }
                    )
                    try validatePath()
                    try cleanupBoundaryHandler?(
                        .didQuarantineLease(
                            source: leaseURL,
                            destination: destination
                        )
                    )
                }
                guard let quarantineURL else {
                    throw DebugEditorFindFixture.FixtureError.unsafeLease
                }
                try validatePath()
                unlinkAttemptStarted = true
                try rootHandle.removeRegularFile(
                    at: quarantineURL,
                    expectedIdentity: leaseIdentity,
                    afterUnlink: {
                        try cleanupBoundaryHandler?(
                            .didUnlinkLeaseQuarantine(quarantineURL)
                        )
                    }
                )
                didUnlinkPath = true
            }
            guard let quarantineURL,
                  try rootHandle.regularFileIdentity(at: quarantineURL) == nil,
                  try linkCount() == 0
            else {
                throw DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete
            }
            isVerifiedUnlinked = true
        }

        private func reconcileRecordedMutation() throws {
            let retainedLinkCount = try linkCount()
            if unlinkAttemptStarted, retainedLinkCount == 0 {
                guard let quarantineURL,
                      try rootHandle.regularFileIdentity(at: quarantineURL) == nil
                else {
                    throw DebugEditorFindFixture.FixtureError
                        .fixtureRemovalDidNotComplete
                }
                didUnlinkPath = true
                return
            }
            guard retainedLinkCount == 1 else {
                throw DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete
            }
            guard let quarantineURL else {
                try validatePath()
                return
            }

            let quarantineIdentity = try rootHandle.regularFileIdentity(
                at: quarantineURL
            )
            if quarantineIdentity == leaseIdentity {
                try validatePath()
                return
            }
            let publishedIdentity = try rootHandle.regularFileIdentity(
                at: leaseURL
            )
            guard publishedIdentity == leaseIdentity else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
            self.quarantineURL = nil
            unlinkAttemptStarted = false
            try validatePath()
        }

        private static func validateDescriptor(
            _ descriptor: Int32,
            matches leaseURL: URL,
            rootHandle: DebugEditorFindFixtureRootHandle
        ) throws -> DebugEditorFindFixture.EntryIdentity {
            try rootHandle.validateRegularFileDescriptor(
                descriptor,
                at: leaseURL
            )
        }

        private static func makeRootHandle(
            for leaseURL: URL
        ) throws -> DebugEditorFindFixtureRootHandle {
            let fixturesRoot = leaseURL.deletingLastPathComponent()
            guard let rootStatus = try DebugEditorFindFixture.entryStatus(
                at: fixturesRoot
            ), DebugEditorFindFixture.fileType(of: rootStatus) == mode_t(S_IFDIR)
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeFixturesRoot
            }
            return try DebugEditorFindFixtureRootHandle(
                fixturesRoot: fixturesRoot,
                expectedIdentity: DebugEditorFindFixture.identity(of: rootStatus)
            )
        }
    }
#endif
