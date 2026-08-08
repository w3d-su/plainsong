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
    }

    extension DebugEditorFindFixtureWorkspaceHandle {
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

        static func reopen(
            at workspaceURL: URL,
            binding: DebugEditorFindFixtureLease.WorkspaceBinding
        ) throws -> DebugEditorFindFixtureWorkspaceHandle {
            guard let expected = binding.validatedIdentity else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
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
                guard identity == expected.workspace else {
                    throw DebugEditorFindFixture.FixtureError
                        .unsafeCreatedFixture
                }
                ownershipMarkerDescriptor = expected.ownershipMarkerName
                    .withCString { markerName in
                        openat(
                            descriptor,
                            markerName,
                            O_RDWR | O_CLOEXEC | O_NOFOLLOW
                        )
                    }
                guard ownershipMarkerDescriptor >= 0,
                      try regularFileIdentity(ownershipMarkerDescriptor)
                      == expected.ownershipMarker
                else {
                    throw DebugEditorFindFixture.FixtureError
                        .unsafeCreatedFixture
                }
                let handle = DebugEditorFindFixtureWorkspaceHandle(
                    descriptor: descriptor,
                    ownershipMarkerDescriptor: ownershipMarkerDescriptor,
                    ownershipMarkerName: expected.ownershipMarkerName,
                    workspaceURL: workspaceURL,
                    workspaceIdentity: expected.workspace,
                    ownershipMarkerIdentity: expected.ownershipMarker
                )
                descriptor = -1
                ownershipMarkerDescriptor = -1
                try handle.validatePath(at: workspaceURL)
                return handle
            } catch {
                if ownershipMarkerDescriptor >= 0 {
                    close(ownershipMarkerDescriptor)
                }
                if descriptor >= 0 {
                    close(descriptor)
                }
                throw error
            }
        }

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
            let descriptorIdentity = try Self.descriptorIdentity(descriptor)
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
                try Self.removeContents(
                    of: descriptor,
                    excluding: [ownershipMarkerName],
                    afterRemovingChild: afterRemovingChild
                )
                try removeOwnershipMarker(
                    at: workspaceURL,
                    cleanupBoundaryHandler: cleanupBoundaryHandler
                )
            }
            guard try Self.childNames(of: descriptor).isEmpty,
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

        private static func removeContents(
            of directoryDescriptor: Int32,
            excluding excludedNames: Set<String> = [],
            afterRemovingChild: ((String) throws -> Void)? = nil
        ) throws {
            let names = try childNames(of: directoryDescriptor)
                .filter { !excludedNames.contains($0) }
                .sorted()
            for name in names {
                try removeChild(named: name, from: directoryDescriptor)
                try afterRemovingChild?(name)
            }
            guard try Set(childNames(of: directoryDescriptor)) == excludedNames,
                  fsync(directoryDescriptor) == 0
            else {
                throw DebugEditorFindFixture.FixtureError
                    .fixtureRemovalDidNotComplete
            }
        }

        private static func removeChild(
            named name: String,
            from directoryDescriptor: Int32,
            expectedIdentity:
            DebugEditorFindFixture.EntryIdentity? = nil
        ) throws {
            var pathStatus = stat()
            let inspectionResult = name.withCString { childName in
                fstatat(
                    directoryDescriptor,
                    childName,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard inspectionResult == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errno)
            }
            if let expectedIdentity,
               DebugEditorFindFixture.identity(of: pathStatus) != expectedIdentity
            {
                throw DebugEditorFindFixture.FixtureError
                    .unsafeCreatedFixture
            }
            guard DebugEditorFindFixture.fileType(of: pathStatus)
                == mode_t(S_IFDIR)
            else {
                let removalResult = name.withCString { childName in
                    unlinkat(directoryDescriptor, childName, 0)
                }
                guard removalResult == 0 else {
                    throw DebugEditorFindFixture.FixtureError
                        .couldNotRemoveWorkspace(errno)
                }
                return
            }

            let childDescriptor = name.withCString { childName in
                openat(
                    directoryDescriptor,
                    childName,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard childDescriptor >= 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errno)
            }
            defer { close(childDescriptor) }
            let childIdentity = try descriptorIdentity(childDescriptor)
            guard childIdentity == DebugEditorFindFixture.identity(of: pathStatus) else {
                throw DebugEditorFindFixture.FixtureError.unsafeCreatedFixture
            }
            try removeContents(of: childDescriptor)

            var finalStatus = stat()
            let reinspectionResult = name.withCString { childName in
                fstatat(
                    directoryDescriptor,
                    childName,
                    &finalStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard reinspectionResult == 0,
                  DebugEditorFindFixture.fileType(of: finalStatus)
                  == mode_t(S_IFDIR),
                  DebugEditorFindFixture.identity(of: finalStatus)
                  == childIdentity
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeCreatedFixture
            }
            let removalResult = name.withCString { childName in
                unlinkat(directoryDescriptor, childName, AT_REMOVEDIR)
            }
            guard removalResult == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotRemoveWorkspace(errno)
            }
        }

        private static func childNames(
            of directoryDescriptor: Int32
        ) throws -> [String] {
            let independentDescriptor = openat(
                directoryDescriptor,
                ".",
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard independentDescriptor >= 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errno)
            }
            guard let stream = fdopendir(independentDescriptor) else {
                let errorCode = errno
                close(independentDescriptor)
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errorCode)
            }
            defer { closedir(stream) }

            var names = [String]()
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    let errorCode = errno
                    guard errorCode == 0 else {
                        throw DebugEditorFindFixture.FixtureError
                            .couldNotInspectFixture(errorCode)
                    }
                    return names
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(
                        to: CChar.self,
                        capacity: Int(MAXNAMLEN) + 1
                    ) {
                        String(cString: $0)
                    }
                }
                if name != ".", name != ".." {
                    names.append(name)
                }
            }
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

        private func removeOwnershipMarker(
            at currentWorkspaceURL: URL,
            cleanupBoundaryHandler: EditorFindFixtureCleanupHandler?
        ) throws {
            guard try reconcileOwnershipMarkerRemoval() == .linked else {
                return
            }
            ownershipMarkerRemovalState = .attempted
            do {
                try Self.removeChild(
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
