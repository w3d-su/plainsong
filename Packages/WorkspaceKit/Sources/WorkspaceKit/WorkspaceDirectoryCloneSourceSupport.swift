import Darwin
import Foundation

enum WorkspaceDirectoryCloneSourceSupport {
    static func makeUnlinkedSource(
        appropriateFor destination: WorkspaceFileSystemLocation,
        hooks: WorkspaceItemCreationHooks
    ) throws -> WorkspaceDirectoryCloneSource {
        let createdURL = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination.rootURL,
            create: true
        )
        let createdPath = try WorkspaceLiteralFileURL.absolutePath(of: createdURL)
        let descriptor = Darwin.open(
            createdPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw WorkspaceItemMutationFailure.unreadable
        }
        var shouldClose = true
        defer {
            if shouldClose {
                Darwin.close(descriptor)
            }
        }

        let namedSnapshot = try sourceSnapshot(
            descriptor: descriptor,
            requiresNamedLink: true
        )
        try validateNamedSource(
            at: createdURL,
            expecting: namedSnapshot
        )
        hooks.emit(.willUnlinkDirectorySource(descriptor, createdURL))

        // macOS 14 has no conditional directory unlink by descriptor. This cleanup is
        // restricted to the OS-created random item-replacement name, never a workspace
        // name, and the final identity/policy proof is immediately adjacent to rmdir.
        // A same-user swap in that remaining syscall gap is a platform residual.
        try validateNamedSource(
            at: createdURL,
            expecting: namedSnapshot
        )
        hooks.emit(.willRemoveVerifiedDirectorySource(descriptor, createdURL))
        guard Darwin.rmdir(createdPath) == 0 else {
            throw WorkspaceItemMutationFailure.unreadable
        }
        try validatePathIsMissing(createdPath)

        let unlinkedSnapshot = try sourceSnapshot(
            descriptor: descriptor,
            requiresNamedLink: false
        )
        guard unlinkedSnapshot.matchesIdentityAndAttributes(namedSnapshot) else {
            throw WorkspaceItemMutationFailure.unreadable
        }

        shouldClose = false
        return WorkspaceDirectoryCloneSource(
            descriptor: descriptor,
            policy: unlinkedSnapshot.policy,
            reportedPath: unlinkedSnapshot.reportedPath
        )
    }

    static func validateUnlinkedSource(
        _ source: WorkspaceDirectoryCloneSource,
        expectedDevice: UInt64
    ) throws {
        let snapshot = try sourceSnapshot(
            descriptor: source.descriptor,
            requiresNamedLink: false
        )
        guard snapshot.identity.device == expectedDevice else {
            throw WorkspaceItemMutationFailure.crossDevice
        }
        guard snapshot.policy == source.policy else {
            throw WorkspaceItemMutationFailure.unreadable
        }
        guard snapshot.reportedPath == source.reportedPath else {
            throw WorkspaceItemMutationFailure.unreadable
        }
    }

    static func captureCreatedDirectoryPolicy(
        descriptor: Int32
    ) throws -> WorkspaceDirectoryClonePolicy {
        // APFS may lazily materialize system-managed xattr state on the first
        // descriptor read. Warm that state before choosing the ctime baseline;
        // every subsequent read is still required to remain byte-for-byte and
        // ctime stable.
        _ = try descriptorExtendedAttributes(descriptor)
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFDIR,
              before.st_uid == Darwin.geteuid(),
              (before.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)) == S_IRWXU,
              before.st_flags == 0,
              try directoryDescriptorIsEmpty(descriptor)
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        let beforeAttributes = try descriptorExtendedAttributes(descriptor)
        let afterAttributes = try descriptorExtendedAttributes(descriptor)
        guard beforeAttributes == afterAttributes else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_mode == after.st_mode,
              before.st_uid == after.st_uid,
              before.st_gid == after.st_gid,
              before.st_nlink == after.st_nlink,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              before.st_flags == after.st_flags
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        return WorkspaceDirectoryClonePolicy(
            changeSeconds: Int64(after.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(after.st_ctimespec.tv_nsec),
            extendedAttributes: afterAttributes
        )
    }

    static func validateCreatedDirectory(
        descriptor: Int32,
        expecting expectedPolicy: WorkspaceDirectoryClonePolicy
    ) throws {
        guard try captureCreatedDirectoryPolicy(
            descriptor: descriptor
        ) == expectedPolicy else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
    }
}

private extension WorkspaceDirectoryCloneSourceSupport {
    struct SourceSnapshot: Equatable {
        let identity: WorkspaceFileSystemIdentity
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let flags: UInt32
        let policy: WorkspaceDirectoryClonePolicy
        let reportedPath: Data

        func matchesIdentityAndAttributes(
            _ other: SourceSnapshot
        ) -> Bool {
            identity == other.identity &&
                mode == other.mode &&
                owner == other.owner &&
                group == other.group &&
                flags == other.flags &&
                policy.extendedAttributes == other.policy.extendedAttributes &&
                reportedPath == other.reportedPath
        }
    }

    static func validateNamedSource(
        at location: URL,
        expecting expectedSnapshot: SourceSnapshot
    ) throws {
        let currentDescriptor = try Darwin.open(
            WorkspaceLiteralFileURL.absolutePath(of: location),
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard currentDescriptor >= 0 else {
            throw WorkspaceItemMutationFailure.unreadable
        }
        defer { Darwin.close(currentDescriptor) }
        guard try sourceSnapshot(
            descriptor: currentDescriptor,
            requiresNamedLink: true
        ) == expectedSnapshot else {
            throw WorkspaceItemMutationFailure.unreadable
        }
    }

    static func sourceSnapshot(
        descriptor: Int32,
        requiresNamedLink: Bool
    ) throws -> SourceSnapshot {
        // The first read of an OS-created replacement directory's system xattrs
        // can legitimately advance ctime. Stabilize that lazy materialization
        // before capturing the policy that protects later clone boundaries.
        _ = try descriptorExtendedAttributes(descriptor)
        let beforeReportedPath = try descriptorReportedPath(descriptor)
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFDIR,
              before.st_uid == Darwin.geteuid(),
              (before.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)) == S_IRWXU,
              !requiresNamedLink || before.st_nlink == 2,
              before.st_flags == 0,
              try directoryDescriptorIsEmpty(descriptor)
        else {
            throw WorkspaceItemMutationFailure.unreadable
        }
        let beforeAttributes = try descriptorExtendedAttributes(descriptor)
        let afterAttributes = try descriptorExtendedAttributes(descriptor)
        guard beforeAttributes == afterAttributes else {
            throw WorkspaceItemMutationFailure.unreadable
        }

        var after = stat()
        let afterReportedPath = try descriptorReportedPath(descriptor)
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_mode == after.st_mode,
              before.st_uid == after.st_uid,
              before.st_gid == after.st_gid,
              before.st_nlink == after.st_nlink,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              before.st_flags == after.st_flags,
              beforeReportedPath == afterReportedPath
        else {
            throw WorkspaceItemMutationFailure.unreadable
        }
        return SourceSnapshot(
            identity: WorkspaceFileSystemIdentity(
                device: UInt64(after.st_dev),
                inode: UInt64(after.st_ino)
            ),
            mode: after.st_mode,
            owner: after.st_uid,
            group: after.st_gid,
            flags: after.st_flags,
            policy: WorkspaceDirectoryClonePolicy(
                changeSeconds: Int64(after.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(after.st_ctimespec.tv_nsec),
                extendedAttributes: afterAttributes
            ),
            reportedPath: afterReportedPath
        )
    }

    static func descriptorExtendedAttributes(
        _ descriptor: Int32
    ) throws -> [String: WorkspaceDirectoryExtendedAttributeValue] {
        let count = Darwin.flistxattr(descriptor, nil, 0, 0)
        guard count >= 0 else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        guard count > 0 else { return [:] }

        var buffer = [CChar](repeating: 0, count: count)
        let readCount = buffer.withUnsafeMutableBufferPointer {
            Darwin.flistxattr(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard readCount == count else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        let names = buffer
            .map { UInt8(bitPattern: $0) }
            .split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
        let allowedNames = Set([
            "com.apple.macl",
            "com.apple.provenance",
            "com.apple.quarantine",
        ])
        guard names.allSatisfy(allowedNames.contains) else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }

        var attributes: [String: WorkspaceDirectoryExtendedAttributeValue] = [:]
        for name in names {
            let size = name.withCString {
                Darwin.fgetxattr(descriptor, $0, nil, 0, 0, 0)
            }
            if size < 0, errno == EPERM || errno == EACCES {
                attributes[name] = .accessControlled
                continue
            }
            guard size >= 0 else {
                throw WorkspaceAnchoredFileSystemError.unreadable
            }
            var value = Data(count: size)
            let readCount = name.withCString { namePointer in
                value.withUnsafeMutableBytes {
                    Darwin.fgetxattr(
                        descriptor,
                        namePointer,
                        $0.baseAddress,
                        $0.count,
                        0,
                        0
                    )
                }
            }
            guard readCount == size else {
                throw WorkspaceAnchoredFileSystemError.unreadable
            }
            attributes[name] = .readable(value)
        }
        return attributes
    }

    static func descriptorReportedPath(
        _ descriptor: Int32
    ) throws -> Data {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_FULLPATH)
        var buffer = [UInt8](
            repeating: 0,
            count: Int(MAXPATHLEN) + 32
        )
        let result = buffer.withUnsafeMutableBytes {
            Darwin.fgetattrlist(
                descriptor,
                &attributes,
                $0.baseAddress,
                $0.count,
                0
            )
        }
        guard result == 0 else {
            throw WorkspaceItemMutationFailure.unreadable
        }

        let path = buffer.withUnsafeBytes { bytes -> Data? in
            let lengthSize = MemoryLayout<UInt32>.size
            let referenceSize = MemoryLayout<attrreference_t>.size
            guard bytes.count >= lengthSize + referenceSize else {
                return nil
            }
            let returnedLength = Int(bytes.load(as: UInt32.self))
            guard returnedLength >= lengthSize + referenceSize,
                  returnedLength <= bytes.count
            else {
                return nil
            }
            let referenceAddress = bytes.baseAddress!.advanced(by: lengthSize)
            let reference = referenceAddress.load(as: attrreference_t.self)
            let pathStart = lengthSize + Int(reference.attr_dataoffset)
            let pathLength = Int(reference.attr_length)
            guard pathLength > 1,
                  pathStart >= lengthSize + referenceSize,
                  pathStart <= returnedLength,
                  pathLength <= returnedLength - pathStart
            else {
                return nil
            }
            let pathBytes = bytes[pathStart ..< pathStart + pathLength]
            guard pathBytes.first == UInt8(ascii: "/"),
                  pathBytes.last == 0,
                  !pathBytes.dropLast().contains(0)
            else {
                return nil
            }
            return Data(pathBytes.dropLast())
        }
        guard let path else {
            throw WorkspaceItemMutationFailure.unreadable
        }
        return path
    }

    static func validatePathIsMissing(
        _ path: String
    ) throws {
        var status = stat()
        guard Darwin.lstat(path, &status) != 0, errno == ENOENT else {
            throw WorkspaceItemMutationFailure.unreadable
        }
    }

    static func directoryDescriptorIsEmpty(
        _ descriptor: Int32
    ) throws -> Bool {
        let enumerationDescriptor = Darwin.dup(descriptor)
        guard enumerationDescriptor >= 0 else {
            throw WorkspaceItemMutationFailure.unreadable
        }
        guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw WorkspaceItemMutationFailure.unreadable
        }
        defer { Darwin.closedir(directory) }
        Darwin.rewinddir(directory)

        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                return false
            }
        }
        guard errno == 0 else {
            throw WorkspaceItemMutationFailure.unreadable
        }
        return true
    }
}
