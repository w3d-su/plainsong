import Darwin
import Foundation

extension WorkspaceAnchoredFileSystem {
    /// The staging file's create mode. A replacement starts owner-only and receives the
    /// replaced file's rwx bits before publication, so it is never briefly more permissive
    /// than the original. A new file is created `0666` for the kernel to apply the umask, as
    /// any other app's new document is; it used to keep the `0600` staging mode for good.
    static func stagingCreationMode(for target: WriteTarget) -> mode_t {
        switch target {
        case .existing: mode_t(S_IRUSR | S_IWUSR)
        case .missing: mode_t(0o666)
        }
    }

    /// Carries the replaced file's own metadata onto the prepared inode before the swap
    /// publishes it: extended attributes (Finder tags, `com.apple.FinderInfo` colors,
    /// `kMDItemWhereFroms`, quarantine), the extended ACL and the creation date. Without
    /// this a save, autosave included, silently dropped all of them, because publication
    /// replaces the inode.
    ///
    /// Every step is best effort: the bytes are what a save promises, so a metadata copy
    /// the volume or the sandbox refuses never fails the write. Attributes the system owns
    /// for each inode (`com.apple.macl`, `com.apple.provenance`, compression and the
    /// `com.apple.system.` namespace) are not copied. Hard links cannot be kept by any
    /// rename-based publication; the other names keep the displaced inode.
    static func copyPreservedMetadata(from source: Int32, to destination: Int32) {
        copyExtendedAttributes(from: source, to: destination)
        copyExtendedACL(from: source, to: destination)
        copyCreationDate(from: source, to: destination)
    }

    static func isPreservedExtendedAttribute(_ name: String) -> Bool {
        !(name == "com.apple.macl"
            || name == "com.apple.provenance"
            || name == "com.apple.decmpfs"
            || name.hasPrefix("com.apple.system."))
    }

    private static func copyExtendedAttributes(from source: Int32, to destination: Int32) {
        let listSize = Darwin.flistxattr(source, nil, 0, 0)
        guard listSize > 0 else { return }
        var nameBuffer = [CChar](repeating: 0, count: listSize)
        let listed = Darwin.flistxattr(source, &nameBuffer, listSize, 0)
        guard listed > 0 else { return }

        var start = 0
        for index in 0 ..< listed where nameBuffer[index] == 0 {
            let name = String(cString: Array(nameBuffer[start ... index]))
            start = index + 1
            guard !name.isEmpty, isPreservedExtendedAttribute(name) else { continue }
            copyExtendedAttribute(named: name, from: source, to: destination)
        }
    }

    private static func copyExtendedAttribute(named name: String, from source: Int32, to destination: Int32) {
        let size = Darwin.fgetxattr(source, name, nil, 0, 0, 0)
        guard size >= 0 else { return }
        var value = [UInt8](repeating: 0, count: max(size, 1))
        let read = Darwin.fgetxattr(source, name, &value, size, 0, 0)
        guard read == size else { return }
        _ = Darwin.fsetxattr(destination, name, value, size, 0, 0)
    }

    private static func copyExtendedACL(from source: Int32, to destination: Int32) {
        guard let acl = acl_get_fd_np(source, ACL_TYPE_EXTENDED) else { return }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        _ = acl_set_fd_np(destination, acl, ACL_TYPE_EXTENDED)
    }

    private static func copyCreationDate(from source: Int32, to destination: Int32) {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)

        // The returned buffer is a 32-bit length followed by the timespec, packed on a
        // 4-byte boundary, so the timespec is read unaligned.
        let lengthSize = MemoryLayout<UInt32>.size
        var buffer = [UInt8](repeating: 0, count: lengthSize + MemoryLayout<timespec>.size)
        let read = buffer.withUnsafeMutableBytes {
            Darwin.fgetattrlist(source, &attributes, $0.baseAddress, $0.count, 0)
        }
        guard read == 0 else { return }
        var creationTime = buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: lengthSize, as: timespec.self)
        }
        _ = withUnsafeMutablePointer(to: &creationTime) {
            Darwin.fsetattrlist(destination, &attributes, $0, MemoryLayout<timespec>.size, 0)
        }
    }
}
