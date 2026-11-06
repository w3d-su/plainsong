import Darwin

extension WorkspaceAnchoredFileSystem {
    /// What the destination volume reports about writing to it. A rename capability counts only
    /// when `ATTR_VOL_CAPABILITIES` marks its bit both valid and set.
    struct VolumeWriteCapabilities: Equatable, Sendable {
        let isReadOnly: Bool
        let exclusiveRename: Bool
        let swapRename: Bool
    }

    /// Reads the capabilities through an open descriptor on the volume (`fstatfs` and
    /// `fgetattrlist`), so no path is resolved. `nil` when either call fails or the reply is short.
    static func volumeWriteCapabilities(descriptor: Int32) -> VolumeWriteCapabilities? {
        var fileSystem = statfs()
        guard Darwin.fstatfs(descriptor, &fileSystem) == 0 else { return nil }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        // The reply is the returned-length word followed by `vol_capabilities_attr_t`:
        // four capability words, then four valid words.
        let lengthSize = MemoryLayout<UInt32>.size
        let wordSize = MemoryLayout<UInt32>.size
        let replySize = lengthSize + MemoryLayout<vol_capabilities_attr_t>.size
        var reply = [UInt8](repeating: 0, count: replySize)
        let result = reply.withUnsafeMutableBytes {
            Darwin.fgetattrlist(descriptor, &attributes, $0.baseAddress, $0.count, 0)
        }
        guard result == 0 else { return nil }
        return reply.withUnsafeBytes { bytes -> VolumeWriteCapabilities? in
            let returnedLength = Int(bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            guard returnedLength >= replySize else { return nil }
            let interfaces = Int(VOL_CAPABILITIES_INTERFACES)
            let capabilities = bytes.loadUnaligned(
                fromByteOffset: lengthSize + interfaces * wordSize,
                as: UInt32.self
            )
            let valid = bytes.loadUnaligned(
                fromByteOffset: lengthSize + MemoryLayout<vol_capabilities_set_t>.size + interfaces * wordSize,
                as: UInt32.self
            )
            func advertises(_ bit: Int32) -> Bool {
                let mask = UInt32(bit)
                return valid & mask != 0 && capabilities & mask != 0
            }
            return VolumeWriteCapabilities(
                isReadOnly: fileSystem.f_flags & UInt32(MNT_RDONLY) != 0,
                exclusiveRename: advertises(VOL_CAP_INT_RENAME_EXCL),
                swapRename: advertises(VOL_CAP_INT_RENAME_SWAP)
            )
        }
    }

    /// The reason to refuse a write before anything is staged, or `nil` when the destination
    /// volume can carry the transaction. Every write needs `RENAME_EXCL`: it publishes a missing
    /// leaf and moves an artifact to its cleanup name. Replacing an existing leaf also needs
    /// `RENAME_SWAP`. A volume that does not answer is refused like one that answers no.
    ///
    /// Measured on macOS 27 disk images and recorded in
    /// `docs/decisions/2026-11-06-refuse-saves-on-volumes-without-atomic-rename.md`: exFAT and
    /// FAT32 advertise neither rename, and Mac OS Extended advertises no swap. Neither syscall
    /// result can stand in for the bits. FAT32 returns success for `RENAME_SWAP` after replacing
    /// the leaf like a plain rename, so the original is no longer rollback material. exFAT and
    /// FAT32 also renumber an empty file's inode on its first write, so a writer that got as far
    /// as staging fails its own identity check and leaves the temporary file behind.
    static func volumeRefusal(
        for target: WriteTarget,
        parentDescriptor: Int32,
        hooks: Hooks
    ) -> WorkspaceAnchoredFileSystemError? {
        guard let capabilities = hooks.volumeWriteCapabilities(descriptor: parentDescriptor) else {
            return .unsupportedVolume
        }
        if capabilities.isReadOnly {
            return .readOnlyVolume
        }
        if !capabilities.exclusiveRename {
            return .unsupportedVolume
        }
        if case .existing = target, !capabilities.swapRename {
            return .unsupportedVolume
        }
        return nil
    }

    /// The reason for a failed write-path call: the temporary file's create, truncate, write,
    /// `fsync` or `fchmod`, or a commit rename. A code without a reason of its own keeps the
    /// reason that call reported before (`fallback`).
    static func writeFailure(
        errorNumber: Int32,
        otherwise fallback: WorkspaceAnchoredFileSystemError
    ) -> WorkspaceAnchoredFileSystemError {
        switch errorNumber {
        case ENOTSUP: .unsupportedVolume
        case ENOSPC, EDQUOT: .insufficientSpace
        case EROFS: .readOnlyVolume
        case EPERM, EACCES: .writeNotPermitted
        default: fallback
        }
    }
}

extension WorkspaceAnchoredFileSystem.Hooks {
    func volumeWriteCapabilities(
        descriptor: Int32
    ) -> WorkspaceAnchoredFileSystem.VolumeWriteCapabilities? {
        if let volumeWriteCapabilitiesProvider {
            return volumeWriteCapabilitiesProvider(descriptor)
        }
        return WorkspaceAnchoredFileSystem.volumeWriteCapabilities(descriptor: descriptor)
    }
}
