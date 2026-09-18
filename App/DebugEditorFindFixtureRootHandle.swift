#if DEBUG
    import Darwin
    import Foundation

    /// An exact descriptor for the fixture root used for child-relative quarantine renames.
    final class DebugEditorFindFixtureRootHandle {
        private let descriptor: Int32
        private let fixturesRoot: URL
        private let identity: DebugEditorFindFixture.EntryIdentity

        init(
            fixturesRoot: URL,
            expectedIdentity: DebugEditorFindFixture.EntryIdentity
        ) throws {
            self.fixturesRoot = fixturesRoot.standardizedFileURL
            identity = expectedIdentity
            descriptor = self.fixturesRoot.path.withCString { path in
                Darwin.open(
                    path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard descriptor >= 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errno)
            }
            // `deinit` is the only closer. Closing here would double-close after
            // the stored properties are already initialized.
            try validatePath()
        }

        deinit {
            if descriptor >= 0 {
                close(descriptor)
            }
        }

        func validatePath() throws {
            var descriptorStatus = stat()
            guard fstat(descriptor, &descriptorStatus) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectFixture(errno)
            }
            guard DebugEditorFindFixture.fileType(of: descriptorStatus)
                == mode_t(S_IFDIR),
                DebugEditorFindFixture.identity(of: descriptorStatus) == identity,
                let pathStatus = try DebugEditorFindFixture.entryStatus(
                    at: fixturesRoot
                ),
                DebugEditorFindFixture.fileType(of: pathStatus)
                == mode_t(S_IFDIR),
                DebugEditorFindFixture.identity(of: pathStatus) == identity,
                try currentKernelURL().resolvingSymlinksInPath()
                == fixturesRoot.resolvingSymlinksInPath()
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeFixturesRoot
            }
        }

        func quarantine(
            source: URL,
            destination: URL,
            afterRename: (() throws -> Void)? = nil
        ) throws {
            let source = source.standardizedFileURL
            let destination = destination.standardizedFileURL
            guard source.deletingLastPathComponent() == fixturesRoot,
                  destination.deletingLastPathComponent() == fixturesRoot,
                  !source.lastPathComponent.isEmpty,
                  !destination.lastPathComponent.isEmpty,
                  source.lastPathComponent != destination.lastPathComponent
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeCreatedFixture
            }
            try validatePath()
            let result = source.lastPathComponent.withCString { sourceName in
                destination.lastPathComponent.withCString { destinationName in
                    Darwin.renameatx_np(
                        descriptor,
                        sourceName,
                        descriptor,
                        destinationName,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            guard result == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotQuarantineWorkspace(errno)
            }
            try afterRename?()
            guard fsync(descriptor) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotSynchronizeFixturesRoot(errno)
            }
            try validatePath()
        }

        func removeEmptyDirectory(
            at directoryURL: URL,
            expectedIdentity: DebugEditorFindFixture.EntryIdentity
        ) throws {
            let directoryURL = try validatedDirectChild(directoryURL)
            try validatePath()
            var pathStatus = stat()
            let inspectionResult = directoryURL.lastPathComponent.withCString { name in
                fstatat(
                    descriptor,
                    name,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard inspectionResult == 0,
                  DebugEditorFindFixture.fileType(of: pathStatus)
                  == mode_t(S_IFDIR),
                  DebugEditorFindFixture.identity(of: pathStatus)
                  == expectedIdentity
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeCreatedFixture
            }
            let removalResult = directoryURL.lastPathComponent.withCString { name in
                unlinkat(descriptor, name, AT_REMOVEDIR)
            }
            guard removalResult == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotRemoveWorkspace(errno)
            }
            try synchronizeAndValidate()
        }

        func removeRegularFile(
            at fileURL: URL,
            expectedIdentity: DebugEditorFindFixture.EntryIdentity,
            afterUnlink: (() throws -> Void)? = nil
        ) throws {
            let fileURL = try validateRegularFile(
                at: fileURL,
                expectedIdentity: expectedIdentity
            )
            let removalResult = fileURL.lastPathComponent.withCString { name in
                unlinkat(descriptor, name, 0)
            }
            guard removalResult == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotRemoveLease(errno)
            }
            try afterUnlink?()
            try synchronizeAndValidate()
        }

        func validateRegularFile(
            at fileURL: URL,
            expectedIdentity: DebugEditorFindFixture.EntryIdentity
        ) throws -> URL {
            let fileURL = try validatedDirectChild(fileURL)
            guard try regularFileIdentity(at: fileURL) == expectedIdentity
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
            return fileURL
        }

        func regularFileIdentity(
            at fileURL: URL
        ) throws -> DebugEditorFindFixture.EntryIdentity? {
            let fileURL = try validatedDirectChild(fileURL)
            try validatePath()
            var pathStatus = stat()
            let inspectionResult = fileURL.lastPathComponent.withCString { name in
                fstatat(
                    descriptor,
                    name,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            if inspectionResult != 0 {
                let errorCode = errno
                guard errorCode == ENOENT else {
                    throw DebugEditorFindFixture.FixtureError
                        .couldNotInspectLease(errorCode)
                }
                try validatePath()
                return nil
            }
            guard DebugEditorFindFixture.fileType(of: pathStatus)
                == mode_t(S_IFREG)
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
            try validatePath()
            return DebugEditorFindFixture.identity(of: pathStatus)
        }

        func createRegularFile(at fileURL: URL) throws -> Int32 {
            let fileURL = try validatedDirectChild(fileURL)
            try validatePath()
            let fileDescriptor = fileURL.lastPathComponent.withCString { name in
                openat(
                    descriptor,
                    name,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard fileDescriptor >= 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotCreateLease(errno)
            }
            do {
                _ = try validateRegularFileDescriptor(
                    fileDescriptor,
                    at: fileURL
                )
                return fileDescriptor
            } catch {
                close(fileDescriptor)
                throw error
            }
        }

        func openRegularFile(at fileURL: URL) throws -> Int32? {
            let fileURL = try validatedDirectChild(fileURL)
            try validatePath()
            let fileDescriptor = fileURL.lastPathComponent.withCString { name in
                openat(
                    descriptor,
                    name,
                    O_RDWR | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard fileDescriptor >= 0 else {
                let errorCode = errno
                if errorCode == ENOENT {
                    return nil
                }
                throw DebugEditorFindFixture.FixtureError
                    .couldNotOpenLease(errorCode)
            }
            do {
                _ = try validateRegularFileDescriptor(
                    fileDescriptor,
                    at: fileURL
                )
                return fileDescriptor
            } catch {
                close(fileDescriptor)
                throw error
            }
        }

        func validateRegularFileDescriptor(
            _ fileDescriptor: Int32,
            at fileURL: URL
        ) throws -> DebugEditorFindFixture.EntryIdentity {
            let fileURL = try validatedDirectChild(fileURL)
            try validatePath()
            var descriptorStatus = stat()
            guard fstat(fileDescriptor, &descriptorStatus) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotInspectLease(errno)
            }
            guard DebugEditorFindFixture.fileType(of: descriptorStatus)
                == mode_t(S_IFREG),
                descriptorStatus.st_nlink == 1
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeLease
            }
            let descriptorIdentity = DebugEditorFindFixture.identity(
                of: descriptorStatus
            )
            _ = try validateRegularFile(
                at: fileURL,
                expectedIdentity: descriptorIdentity
            )
            return descriptorIdentity
        }

        private func validatedDirectChild(_ url: URL) throws -> URL {
            let url = url.standardizedFileURL
            guard url.deletingLastPathComponent() == fixturesRoot,
                  !url.lastPathComponent.isEmpty
            else {
                throw DebugEditorFindFixture.FixtureError.unsafeCreatedFixture
            }
            return url
        }

        private func synchronizeAndValidate() throws {
            guard fsync(descriptor) == 0 else {
                throw DebugEditorFindFixture.FixtureError
                    .couldNotSynchronizeFixturesRoot(errno)
            }
            try validatePath()
        }

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
    }
#endif
