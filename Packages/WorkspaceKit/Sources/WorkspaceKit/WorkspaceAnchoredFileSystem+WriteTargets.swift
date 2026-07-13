import Darwin
import Foundation

extension WorkspaceAnchoredFileSystem {
    enum WriteTarget {
        case existing(
            descriptor: Int32,
            metadata: WorkspaceCoherentFileMetadata,
            permissions: mode_t,
            expectedDigest: String?
        )
        case missing
    }

    struct PreparedWrite {
        let descriptor: Int32
        let name: String
        let location: WorkspaceFileSystemLocation
        let metadata: WorkspaceCoherentFileMetadata
    }

    struct ArtifactRemovalContext {
        let chain: DirectoryDescriptorChain
        let parentDescriptor: Int32
        let hooks: Hooks
    }

    struct WriteCommitContext {
        let prepared: PreparedWrite
        let chain: DirectoryDescriptorChain
        let parentDescriptor: Int32
        let leaf: String
        let hooks: Hooks

        var artifactRemovalContext: ArtifactRemovalContext {
            ArtifactRemovalContext(
                chain: chain,
                parentDescriptor: parentDescriptor,
                hooks: hooks
            )
        }
    }

    struct ExistingWriteContext {
        let originalDescriptor: Int32
        let originalMetadata: WorkspaceCoherentFileMetadata
        let expectedDigest: String?
        let commit: WriteCommitContext
    }

    static func openWriteTarget(
        parentDescriptor: Int32,
        leaf: String,
        expectation: WorkspaceNoFollowFileWriteExpectation
    ) throws -> WriteTarget {
        switch expectation {
        case let .existing(identity):
            return try openExistingWriteTarget(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                expectedIdentity: identity,
                expectedDigest: nil
            )
        case let .existingContent(identity, digest):
            return try openExistingWriteTarget(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                expectedIdentity: identity,
                expectedDigest: digest
            )
        case .missing:
            try validateMissingName(parentDescriptor: parentDescriptor, leaf: leaf)
            return .missing
        case .existingOrMissing:
            do {
                return try existingWriteTarget(
                    parentDescriptor: parentDescriptor,
                    leaf: leaf,
                    requiresReadAccess: false,
                    expectedDigest: nil
                )
            } catch WorkspaceAnchoredFileSystemError.missing {
                return .missing
            }
        }
    }

    static func openExistingWriteTarget(
        parentDescriptor: Int32,
        leaf: String,
        expectedIdentity: WorkspaceFileSystemIdentity,
        expectedDigest: String?
    ) throws -> WriteTarget {
        let target = try existingWriteTarget(
            parentDescriptor: parentDescriptor,
            leaf: leaf,
            requiresReadAccess: expectedDigest != nil,
            expectedDigest: expectedDigest
        )
        guard case let .existing(descriptor, metadata, _, _) = target else {
            throw WorkspaceAnchoredFileSystemError.missing
        }
        guard metadata.identity == expectedIdentity else {
            Darwin.close(descriptor)
            throw WorkspaceAnchoredFileSystemError.changedIdentity
        }
        do {
            if let expectedDigest {
                try validateExpectedContent(
                    descriptor: descriptor,
                    metadata: metadata,
                    expectedDigest: expectedDigest
                )
            }
            try validateNameStillReferencesDescriptor(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                metadata: metadata
            )
            return target
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func existingWriteTarget(
        parentDescriptor: Int32,
        leaf: String,
        requiresReadAccess: Bool,
        expectedDigest: String?
    ) throws -> WriteTarget {
        let descriptor = try openFile(
            parentDescriptor: parentDescriptor,
            leaf: leaf,
            flags: (requiresReadAccess ? O_RDONLY : O_EVTONLY) |
                O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        do {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw WorkspaceAnchoredFileSystemError.unreadable
            }
            guard WorkspaceCoherentFileReader.isRegularFile(status) else {
                throw WorkspaceAnchoredFileSystemError.notRegularFile
            }
            let metadata = WorkspaceCoherentFileReader.metadata(from: status)
            try validateNameStillReferencesDescriptor(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                metadata: metadata
            )
            return .existing(
                descriptor: descriptor,
                metadata: metadata,
                permissions: mode_t(status.st_mode & mode_t(0o7777)),
                expectedDigest: expectedDigest
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func closeWriteTarget(_ target: WriteTarget) {
        if case let .existing(descriptor, _, _, _) = target {
            Darwin.close(descriptor)
        }
    }

    static func prepareTemporaryWrite(
        _ data: Data,
        target: WriteTarget,
        location: WorkspaceFileSystemLocation,
        parentDescriptor: Int32,
        hooks: Hooks
    ) throws -> PreparedWrite {
        let name = ".plainsong-write-\(UUID().uuidString).tmp"
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH)
            )
        }
        guard descriptor >= 0,
              let artifactLocation = location.sibling(named: name)
        else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        hooks.emit(.temporaryFileCreated)

        do {
            if case let .existing(_, _, permissions, _) = target,
               Darwin.fchmod(descriptor, permissions) != 0
            {
                throw WorkspaceAnchoredFileSystemError.unreadable
            }
            try writeAllBytes(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw WorkspaceAnchoredFileSystemError.durabilityFailed
            }
            try checkCancellation()
            let metadata = try regularFileMetadata(descriptor: descriptor)
            hooks.emit(.temporaryFilePrepared)
            return PreparedWrite(
                descriptor: descriptor,
                name: name,
                location: artifactLocation,
                metadata: metadata
            )
        } catch {
            Darwin.close(descriptor)
            throw TemporaryPreparationError(
                reason: normalizedError(error),
                name: name,
                location: artifactLocation
            )
        }
    }

    struct TemporaryPreparationError: Error {
        let reason: WorkspaceAnchoredFileSystemError
        let name: String
        let location: WorkspaceFileSystemLocation
    }

    static func validateExpectedContent(
        descriptor: Int32,
        metadata: WorkspaceCoherentFileMetadata,
        expectedDigest: String
    ) throws {
        let before = try regularFileMetadata(descriptor: descriptor)
        let digest = try sha256Digest(descriptor: descriptor)
        let after = try regularFileMetadata(descriptor: descriptor)
        guard before == after, after == metadata else {
            throw WorkspaceAnchoredFileSystemError.unstable
        }
        guard digest == expectedDigest else {
            throw WorkspaceAnchoredFileSystemError.changedContent
        }
    }

    static func validateExpectedContentAfterSwap(
        descriptor: Int32,
        originalMetadata: WorkspaceCoherentFileMetadata,
        expectedDigest: String
    ) throws {
        let before = try regularFileMetadata(descriptor: descriptor)
        guard before.identity == originalMetadata.identity else {
            throw WorkspaceAnchoredFileSystemError.changedIdentity
        }
        guard before.byteCount == originalMetadata.byteCount else {
            throw WorkspaceAnchoredFileSystemError.changedContent
        }
        let digest = try sha256Digest(descriptor: descriptor)
        let after = try regularFileMetadata(descriptor: descriptor)
        guard before == after else { throw WorkspaceAnchoredFileSystemError.unstable }
        guard digest == expectedDigest else {
            throw WorkspaceAnchoredFileSystemError.changedContent
        }
    }

    static func secureRename(
        parentDescriptor: Int32,
        from source: String,
        to destination: String,
        flags: UInt32
    ) -> Int32 {
        source.withCString { sourcePath in
            destination.withCString { destinationPath in
                Darwin.renameatx_np(
                    parentDescriptor,
                    sourcePath,
                    parentDescriptor,
                    destinationPath,
                    flags | UInt32(RENAME_NOFOLLOW_ANY)
                )
            }
        }
    }

    static func unlink(parentDescriptor: Int32, name: String) -> Int32 {
        name.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
    }

    static func syncDirectory(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw WorkspaceAnchoredFileSystemError.durabilityFailed
        }
    }
}
