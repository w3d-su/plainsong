#if DEBUG
    import Darwin
    import Foundation

    /// A no-follow descriptor for the exact workspace directory created by the app.
    ///
    /// Path absence alone is insufficient cleanup evidence because another process with
    /// app-container access could rename the captured directory between validation and
    /// removal. A retained descriptor for an app-created marker supplies identity-bound
    /// evidence that deletion reached the captured workspace; descriptor-tracked path absence
    /// supplies the complementary directory-name postcondition.
    final class DebugEditorFindFixtureWorkspaceHandle {
        private let descriptor: Int32
        private let ownershipMarkerDescriptor: Int32
        private let ownershipMarkerName: String
        private let workspaceURL: URL
        private let workspaceIdentity: DebugEditorFindFixture.EntryIdentity
        private let ownershipMarkerIdentity: DebugEditorFindFixture.EntryIdentity

        private init(
            descriptor: Int32,
            ownershipMarkerDescriptor: Int32,
            ownershipMarkerName: String,
            workspaceURL: URL,
            workspaceIdentity: DebugEditorFindFixture.EntryIdentity,
            ownershipMarkerIdentity: DebugEditorFindFixture.EntryIdentity
        ) {
            self.descriptor = descriptor
            self.ownershipMarkerDescriptor = ownershipMarkerDescriptor
            self.ownershipMarkerName = ownershipMarkerName
            self.workspaceURL = workspaceURL
            self.workspaceIdentity = workspaceIdentity
            self.ownershipMarkerIdentity = ownershipMarkerIdentity
        }

        deinit {
            close(ownershipMarkerDescriptor)
            close(descriptor)
        }

        static func open(
            at workspaceURL: URL,
            expectedIdentity: DebugEditorFindFixture.EntryIdentity
        ) throws -> DebugEditorFindFixtureWorkspaceHandle {
            var descriptor = workspaceURL.path.withCString { path in
                Darwin.open(
                    path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard descriptor >= 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errno)
            }
            var ownershipMarkerDescriptor = Int32(-1)
            do {
                let identity = try descriptorIdentity(descriptor)
                guard identity == expectedIdentity else {
                    throw DebugEditorFindFixture.FixtureError
                        .unsafeCreatedFixture
                }
                let ownershipMarkerName =
                    DebugEditorFindFixture.ownershipMarkerFilePrefix
                        + UUID().uuidString
                ownershipMarkerDescriptor = ownershipMarkerName.withCString { markerName in
                    openat(
                        descriptor,
                        markerName,
                        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        mode_t(S_IRUSR | S_IWUSR)
                    )
                }
                guard ownershipMarkerDescriptor >= 0 else {
                    throw DebugEditorFindFixture.FixtureError
                        .couldNotCreateWorkspace(errno)
                }
                let ownershipMarkerIdentity = try regularFileIdentity(
                    ownershipMarkerDescriptor
                )
                let handle = DebugEditorFindFixtureWorkspaceHandle(
                    descriptor: descriptor,
                    ownershipMarkerDescriptor: ownershipMarkerDescriptor,
                    ownershipMarkerName: ownershipMarkerName,
                    workspaceURL: workspaceURL,
                    workspaceIdentity: identity,
                    ownershipMarkerIdentity: ownershipMarkerIdentity
                )
                // The handle now owns both descriptors. Clearing the local ownership
                // sentinels prevents the catch path from closing descriptors that its
                // deinitializer already closed if post-construction validation throws.
                descriptor = -1
                ownershipMarkerDescriptor = -1
                try handle.validatePath()
                return handle
            } catch {
                if ownershipMarkerDescriptor >= 0 {
                    close(ownershipMarkerDescriptor)
                }
                close(descriptor)
                throw error
            }
        }

        func validatePath(
            allowingRemovedOwnershipMarker: Bool = false
        ) throws {
            let descriptorIdentity = try Self.descriptorIdentity(descriptor)
            guard descriptorIdentity == workspaceIdentity,
                  let pathStatus = try DebugEditorFindFixture.entryStatus(
                      at: workspaceURL
                  ),
                  DebugEditorFindFixture.fileType(of: pathStatus)
                  == mode_t(S_IFDIR),
                  DebugEditorFindFixture.identity(of: pathStatus)
                  == workspaceIdentity
            else {
                throw DebugEditorFindFixture.FixtureError
                    .unsafeCreatedFixture
            }
            let markerLinkCount = try ownershipMarkerLinkCount()
            if markerLinkCount == 0 {
                guard allowingRemovedOwnershipMarker else {
                    throw DebugEditorFindFixture.FixtureError
                        .unsafeCreatedFixture
                }
            } else {
                guard markerLinkCount == 1 else {
                    throw DebugEditorFindFixture.FixtureError
                        .unsafeCreatedFixture
                }
                try validateOwnershipMarkerPath()
            }
        }

        func verifyRemoved() throws {
            var descriptorStatus = stat()
            guard fstat(descriptor, &descriptorStatus) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errno)
            }
            guard DebugEditorFindFixture.identity(of: descriptorStatus)
                == workspaceIdentity
            else {
                throw DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete
            }
            guard try ownershipMarkerLinkCount() == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete
            }
            let currentKernelURL = try currentKernelURL()
            guard try DebugEditorFindFixture.entryStatus(at: currentKernelURL) == nil else {
                throw DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete
            }
        }

        func workspaceBinding()
            -> DebugEditorFindFixtureLease.WorkspaceBinding
        {
            DebugEditorFindFixtureLease.WorkspaceBinding(
                workspaceIdentity: workspaceIdentity,
                ownershipMarkerName: ownershipMarkerName,
                ownershipMarkerIdentity: ownershipMarkerIdentity
            )
        }

        /// `F_GETPATH` follows an open directory descriptor across rename on macOS. APFS
        /// retains a directory's link count while the descriptor is open, so the kernel's
        /// current descriptor path plus no-follow absence is the usable removal postcondition.
        private func currentKernelURL() throws -> URL {
            var pathBuffer = [CChar](
                repeating: 0,
                count: Int(MAXPATHLEN)
            )
            let result = pathBuffer.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return Int32(-1)
                }
                return Darwin.fcntl(descriptor, F_GETPATH, baseAddress)
            }
            guard result == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errno)
            }
            return pathBuffer.withUnsafeBufferPointer { buffer in
                URL(
                    fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                    isDirectory: true,
                    relativeTo: nil
                )
            }
        }

        private static func descriptorIdentity(
            _ descriptor: Int32
        ) throws -> DebugEditorFindFixture.EntryIdentity {
            var descriptorStatus = stat()
            guard fstat(descriptor, &descriptorStatus) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errno)
            }
            guard DebugEditorFindFixture.fileType(of: descriptorStatus)
                == mode_t(S_IFDIR)
            else {
                throw DebugEditorFindFixture.FixtureError
                    .unsafeCreatedFixture
            }
            return DebugEditorFindFixture.identity(of: descriptorStatus)
        }

        private static func regularFileIdentity(
            _ descriptor: Int32
        ) throws -> DebugEditorFindFixture.EntryIdentity {
            var descriptorStatus = stat()
            guard fstat(descriptor, &descriptorStatus) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errno)
            }
            guard DebugEditorFindFixture.fileType(of: descriptorStatus)
                == mode_t(S_IFREG),
                descriptorStatus.st_nlink == 1
            else {
                throw DebugEditorFindFixture.FixtureError
                    .unsafeCreatedFixture
            }
            return DebugEditorFindFixture.identity(of: descriptorStatus)
        }

        private func validateOwnershipMarkerPath() throws {
            let descriptorIdentity = try Self.regularFileIdentity(
                ownershipMarkerDescriptor
            )
            var pathStatus = stat()
            let result = ownershipMarkerName.withCString { markerName in
                fstatat(
                    descriptor,
                    markerName,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard result == 0,
                  DebugEditorFindFixture.fileType(of: pathStatus)
                  == mode_t(S_IFREG),
                  descriptorIdentity == ownershipMarkerIdentity,
                  DebugEditorFindFixture.identity(of: pathStatus)
                  == ownershipMarkerIdentity
            else {
                throw DebugEditorFindFixture.FixtureError
                    .unsafeCreatedFixture
            }
        }

        private func ownershipMarkerLinkCount() throws -> nlink_t {
            var markerStatus = stat()
            guard fstat(ownershipMarkerDescriptor, &markerStatus) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errno)
            }
            guard DebugEditorFindFixture.fileType(of: markerStatus)
                == mode_t(S_IFREG),
                DebugEditorFindFixture.identity(of: markerStatus)
                == ownershipMarkerIdentity
            else {
                throw DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete
            }
            return markerStatus.st_nlink
        }
    }
#endif
