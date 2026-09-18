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
        private enum OwnershipMarkerRemovalState {
            case notAttempted
            case attempted
            case verifiedUnlinked
        }

        private enum OwnershipMarkerLinkState {
            case linked
            case unlinked
        }

        private let descriptor: Int32
        private let ownershipMarkerDescriptor: Int32
        private let ownershipMarkerName: String
        private let workspaceURL: URL
        private let workspaceIdentity: DebugEditorFindFixture.EntryIdentity
        private let ownershipMarkerIdentity: DebugEditorFindFixture.EntryIdentity
        private var ownershipMarkerRemovalState:
            OwnershipMarkerRemovalState = .notAttempted

        init(
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
    }

    extension DebugEditorFindFixtureWorkspaceHandle {
        func validatePath(
            at currentWorkspaceURL: URL? = nil
        ) throws {
            let currentWorkspaceURL = currentWorkspaceURL ?? workspaceURL
            try validateWorkspacePath(at: currentWorkspaceURL)
            guard try ownershipMarkerLinkCount() == 1 else {
                throw DebugEditorFindFixture.FixtureError
                    .unsafeCreatedFixture
            }
            try validateOwnershipMarkerPath()
        }

        /// Allows only this retained handle to reconcile an ownership-marker unlink that it
        /// recorded before issuing the syscall. A missing marker without that attempt, or any
        /// replacement at the marker name, remains an unsafe fixture.
        func validatePathForRemovalRetry(
            at currentWorkspaceURL: URL
        ) throws {
            try validateWorkspacePath(at: currentWorkspaceURL)
            _ = try reconcileOwnershipMarkerRemoval()
        }

        func canResumeAfterOwnershipMarkerUnlink(
            at currentWorkspaceURL: URL
        ) throws -> Bool {
            guard ownershipMarkerRemovalState != .notAttempted else {
                return false
            }
            try validateWorkspacePath(at: currentWorkspaceURL)
            return try reconcileOwnershipMarkerRemoval() == .unlinked
        }

        private func validateWorkspacePath(
            at currentWorkspaceURL: URL
        ) throws {
            let descriptorIdentity = try DebugEditorFindFixtureWorkspaceHandleIO
                .descriptorIdentity(descriptor)
            guard descriptorIdentity == workspaceIdentity,
                  let pathStatus = try DebugEditorFindFixture.entryStatus(
                      at: currentWorkspaceURL
                  ),
                  DebugEditorFindFixture.fileType(of: pathStatus)
                  == mode_t(S_IFDIR),
                  DebugEditorFindFixture.identity(of: pathStatus)
                  == workspaceIdentity,
                  try currentKernelURL().resolvingSymlinksInPath()
                  == currentWorkspaceURL.resolvingSymlinksInPath()
            else {
                throw DebugEditorFindFixture.FixtureError
                    .unsafeCreatedFixture
            }
        }

        /// Removes children through the retained exact directory descriptor, then performs only
        /// an identity-checked nonrecursive `rmdir` through the retained fixture-root descriptor.
        /// A same-name replacement at `workspaceURL` is never traversed.
        func removeAnchored(
            at workspaceURL: URL,
            rootHandle: DebugEditorFindFixtureRootHandle,
            afterRemovingChild: ((String) throws -> Void)? = nil,
            cleanupBoundaryHandler:
            EditorFindFixtureCleanupHandler? = nil
        ) throws {
            try validateWorkspacePath(at: workspaceURL)
            let markerState = try reconcileOwnershipMarkerRemoval()
            if markerState == .linked {
                try DebugEditorFindFixtureWorkspaceHandleIO.removeContents(
                    of: descriptor,
                    excluding: [ownershipMarkerName],
                    afterRemovingChild: afterRemovingChild
                )
                try removeOwnershipMarker(
                    at: workspaceURL,
                    cleanupBoundaryHandler: cleanupBoundaryHandler
                )
            }
            guard try DebugEditorFindFixtureWorkspaceHandleIO
                .childNames(of: descriptor).isEmpty,
                fsync(descriptor) == 0
            else {
                throw DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete
            }
            try rootHandle.removeEmptyDirectory(
                at: workspaceURL,
                expectedIdentity: workspaceIdentity
            )
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

        private func validateOwnershipMarkerPath() throws {
            let descriptorIdentity = try DebugEditorFindFixtureWorkspaceHandleIO
                .regularFileIdentity(ownershipMarkerDescriptor)
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

        private func removeOwnershipMarker(
            at currentWorkspaceURL: URL,
            cleanupBoundaryHandler: EditorFindFixtureCleanupHandler?
        ) throws {
            guard try reconcileOwnershipMarkerRemoval() == .linked else {
                return
            }
            ownershipMarkerRemovalState = .attempted
            do {
                try DebugEditorFindFixtureWorkspaceHandleIO.removeChild(
                    named: ownershipMarkerName,
                    from: descriptor,
                    expectedIdentity: ownershipMarkerIdentity
                )
                _ = try reconcileOwnershipMarkerRemoval()
            } catch {
                _ = try reconcileOwnershipMarkerRemoval()
                throw error
            }
            try cleanupBoundaryHandler?(
                .didUnlinkWorkspaceOwnershipMarker(
                    currentWorkspaceURL.appendingPathComponent(
                        ownershipMarkerName,
                        isDirectory: false
                    )
                )
            )
        }

        private func reconcileOwnershipMarkerRemoval()
            throws -> OwnershipMarkerLinkState
        {
            let linkCount = try ownershipMarkerLinkCount()
            if ownershipMarkerRemovalState == .notAttempted {
                guard linkCount == 1 else {
                    throw DebugEditorFindFixture.FixtureError
                        .unsafeCreatedFixture
                }
                try validateOwnershipMarkerPath()
                return .linked
            }
            if linkCount == 0 {
                guard try ownershipMarkerPathIsAbsent() else {
                    throw DebugEditorFindFixture.FixtureError
                        .unsafeCreatedFixture
                }
                ownershipMarkerRemovalState = .verifiedUnlinked
                return .unlinked
            }
            guard linkCount == 1,
                  ownershipMarkerRemovalState != .verifiedUnlinked
            else {
                throw DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete
            }
            try validateOwnershipMarkerPath()
            return .linked
        }

        private func ownershipMarkerPathIsAbsent() throws -> Bool {
            var pathStatus = stat()
            let result = ownershipMarkerName.withCString { markerName in
                fstatat(
                    descriptor,
                    markerName,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard result != 0 else {
                return false
            }
            let errorCode = errno
            guard errorCode == ENOENT else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errorCode)
            }
            return true
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
