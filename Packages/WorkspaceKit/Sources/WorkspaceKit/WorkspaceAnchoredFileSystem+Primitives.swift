import CryptoKit
import Darwin
import Foundation

extension WorkspaceAnchoredFileSystem {
    struct DirectoryEntryIdentity: Equatable {
        let identity: WorkspaceFileSystemIdentity
        let fileType: mode_t

        var isDirectory: Bool {
            fileType == S_IFDIR
        }

        var isRegularFile: Bool {
            fileType == S_IFREG
        }
    }

    final class DirectoryDescriptorChain {
        struct Directory {
            let descriptor: Int32
            let componentFromParent: String?
            let identity: WorkspaceFileSystemIdentity
        }

        private(set) var directories: [Directory]
        private let rootIndex: Int
        private let expectedRootIdentity: WorkspaceFileSystemIdentity
        /// Granted root spelling used to re-prove lexical root binding without opening "/".
        private let rootBindingURL: URL

        init(
            directories: [Directory],
            rootIndex: Int,
            expectedRootIdentity: WorkspaceFileSystemIdentity,
            rootBindingURL: URL
        ) {
            self.directories = directories
            self.rootIndex = rootIndex
            self.expectedRootIdentity = expectedRootIdentity
            self.rootBindingURL = rootBindingURL
        }

        deinit {
            for directory in directories.reversed() {
                Darwin.close(directory.descriptor)
            }
        }

        var parentDescriptor: Int32 {
            directories[directories.count - 1].descriptor
        }

        func append(component: String, descriptor: Int32) throws {
            do {
                let identity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(descriptor)
                let entry = try WorkspaceAnchoredFileSystem.directoryEntryIdentity(
                    parentDescriptor: parentDescriptor,
                    component: component
                )
                guard entry.isDirectory, entry.identity == identity else {
                    throw WorkspaceAnchoredFileSystemError.namespaceChanged
                }
                directories.append(Directory(
                    descriptor: descriptor,
                    componentFromParent: component,
                    identity: identity
                ))
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }

        func validateNamespace() throws {
            do {
                // Open root fds follow moved inodes; re-open the granted root spelling
                // (sandbox-allowed) so rename/replace of the lexical root still fails closed
                // without a "/"-anchored ancestor walk.
                try revalidateRootBinding()
                guard directories[rootIndex].identity == expectedRootIdentity else {
                    throw WorkspaceAnchoredFileSystemError.namespaceChanged
                }
                for (index, directory) in directories.enumerated() {
                    guard try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(
                        directory.descriptor
                    ) == directory.identity else {
                        throw WorkspaceAnchoredFileSystemError.namespaceChanged
                    }
                    guard index > 0,
                          let component = directory.componentFromParent
                    else { continue }
                    let entry = try WorkspaceAnchoredFileSystem.directoryEntryIdentity(
                        parentDescriptor: directories[index - 1].descriptor,
                        component: component
                    )
                    guard entry.isDirectory, entry.identity == directory.identity else {
                        throw WorkspaceAnchoredFileSystemError.namespaceChanged
                    }
                }
            } catch WorkspaceAnchoredFileSystemError.cancelled {
                throw WorkspaceAnchoredFileSystemError.cancelled
            } catch {
                throw WorkspaceAnchoredFileSystemError.namespaceChanged
            }
        }

        private func revalidateRootBinding() throws {
            // Do not check Task cancellation here: callers place explicit
            // `checkCancellation` around mutation boundaries, and cleanup after a
            // cancelled write must still revalidate open-fd namespace state.
            let path = try WorkspaceLiteralFileURL.absolutePath(of: rootBindingURL)
            let descriptor = path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                // ENOENT/ENOTDIR: lexical root is gone or no longer a directory → binding lost.
                // EACCES/EPERM/other: skip lexical re-proof (e.g. chmod'd cleanup race) and
                // rely on open root-fd identity checks so an earlier fault is not masked as
                // namespaceChanged. Sandbox EPERM on absolute ancestors is avoided because
                // this opens the granted root spelling, not "/".
                let openError = errno
                if openError == ENOENT || openError == ENOTDIR {
                    throw WorkspaceAnchoredFileSystemError.namespaceChanged
                }
                return
            }
            defer { Darwin.close(descriptor) }
            let identity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(descriptor)
            guard identity == expectedRootIdentity else {
                throw WorkspaceAnchoredFileSystemError.namespaceChanged
            }
        }
    }

    static func withAnchoredParent<T>(
        at location: WorkspaceFileSystemLocation,
        hooks: Hooks,
        _ body: (DirectoryDescriptorChain, Int32, String) throws -> T
    ) throws -> T {
        try checkCancellation()
        // Prove the retained root still names the captured identity via the granted
        // root URL. The App Sandbox permits reopening a Powerbox-selected root, but
        // denies openat from "/" into ancestor components such as "Users".
        try location.rootAuthority.validateCanonicalBinding()
        let expectedRootIdentity = location.rootAuthority.physicalIdentity

        // Dup the retained root descriptor so the chain owns an independent fd and
        // can close it without releasing the authority's lifetime token. Walk only
        // `relativePath` components from that root — never absolute ancestors.
        let rootDescriptor = try location.rootAuthority.withRetainedRootDescriptor { retained in
            let duplicated = Darwin.dup(retained)
            guard duplicated >= 0 else {
                throw WorkspaceAnchoredFileSystemError.unreadable
            }
            return duplicated
        }
        let rootIdentity: WorkspaceFileSystemIdentity
        do {
            rootIdentity = try directoryDescriptorIdentity(rootDescriptor)
        } catch {
            Darwin.close(rootDescriptor)
            throw error
        }
        guard rootIdentity == expectedRootIdentity else {
            Darwin.close(rootDescriptor)
            throw WorkspaceAnchoredFileSystemError.changedIdentity
        }

        let openedDirectories = [DirectoryDescriptorChain.Directory(
            descriptor: rootDescriptor,
            componentFromParent: nil,
            identity: rootIdentity
        )]
        var shouldCloseOpenedDirectories = true
        defer {
            if shouldCloseOpenedDirectories {
                for directory in openedDirectories.reversed() {
                    Darwin.close(directory.descriptor)
                }
            }
        }

        // Chain covers root → parent only. Ancestor-of-root validation is the root
        // authority's own binding proof above, not a "/"-anchored open walk. Mid-op
        // `validateNamespace` re-opens `canonicalRootURL` to detect root rename/replace.
        let rootIndex = 0
        let chain = DirectoryDescriptorChain(
            directories: openedDirectories,
            rootIndex: rootIndex,
            expectedRootIdentity: expectedRootIdentity,
            rootBindingURL: location.rootAuthority.canonicalRootURL
        )
        shouldCloseOpenedDirectories = false
        hooks.emit(.rootAnchored)

        let components = location.relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let leaf = components.last else {
            throw WorkspaceAnchoredFileSystemError.missing
        }
        for component in components.dropLast() {
            try checkCancellation()
            let next = try openDirectory(
                parentDescriptor: chain.parentDescriptor,
                component: component
            )
            try chain.append(component: component, descriptor: next)
            hooks.emit(.componentOpened(component))
        }

        try checkCancellation()
        hooks.emit(.parentAnchored)
        try chain.validateNamespace()
        hooks.emit(.namespaceValidated)
        return try body(chain, chain.parentDescriptor, leaf)
    }

    static func directoryDescriptorIdentity(_ descriptor: Int32) throws -> WorkspaceFileSystemIdentity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            throw WorkspaceAnchoredFileSystemError.notRegularFile
        }
        return WorkspaceFileSystemIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }

    static func validateDirectoryMutationExpectation(
        parentDescriptor: Int32,
        expectation: WorkspaceItemMutationExpectation
    ) throws {
        guard expectation.kind == .directory,
              try directoryDescriptorIdentity(parentDescriptor) == expectation.identity
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
    }

    static func regularFileMetadata(descriptor: Int32) throws -> WorkspaceCoherentFileMetadata {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        guard WorkspaceCoherentFileReader.isRegularFile(status) else {
            throw WorkspaceAnchoredFileSystemError.notRegularFile
        }
        return WorkspaceCoherentFileReader.metadata(from: status)
    }

    static func directoryEntryIdentity(
        parentDescriptor: Int32,
        component: String
    ) throws -> DirectoryEntryIdentity {
        var status = stat()
        let result = component.withCString {
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw errno == ENOENT
                ? WorkspaceAnchoredFileSystemError.missing
                : WorkspaceAnchoredFileSystemError.unreadable
        }
        return DirectoryEntryIdentity(
            identity: WorkspaceFileSystemIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            ),
            fileType: status.st_mode & S_IFMT
        )
    }

    static func validateNameStillReferencesDescriptor(
        parentDescriptor: Int32,
        leaf: String,
        metadata: WorkspaceCoherentFileMetadata
    ) throws {
        let entry: DirectoryEntryIdentity
        do {
            entry = try directoryEntryIdentity(parentDescriptor: parentDescriptor, component: leaf)
        } catch WorkspaceAnchoredFileSystemError.missing {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        guard entry.isRegularFile, entry.identity == metadata.identity else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
    }

    static func validateNameStillReferencesEntry(
        parentDescriptor: Int32,
        leaf: String,
        entry: DirectoryEntryIdentity
    ) throws {
        guard try directoryEntryIdentity(
            parentDescriptor: parentDescriptor,
            component: leaf
        ) == entry else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
    }

    static func validateMissingName(parentDescriptor: Int32, leaf: String) throws {
        do {
            _ = try directoryEntryIdentity(parentDescriptor: parentDescriptor, component: leaf)
            throw WorkspaceAnchoredFileSystemError.changedIdentity
        } catch WorkspaceAnchoredFileSystemError.missing {
            return
        }
    }

    static func openDirectory(parentDescriptor: Int32, component: String) throws -> Int32 {
        let descriptor = component.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw errorForFailedOpen(parentDescriptor: parentDescriptor, component: component)
        }
        return descriptor
    }

    static func openFile(parentDescriptor: Int32, leaf: String, flags: Int32) throws -> Int32 {
        let descriptor = leaf.withCString { Darwin.openat(parentDescriptor, $0, flags) }
        guard descriptor >= 0 else {
            throw errorForFailedOpen(parentDescriptor: parentDescriptor, component: leaf)
        }
        return descriptor
    }

    static func errorForFailedOpen(
        parentDescriptor: Int32,
        component: String
    ) -> WorkspaceAnchoredFileSystemError {
        let openError = errno
        var status = stat()
        let result = component.withCString {
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0, (status.st_mode & S_IFMT) == S_IFLNK { return .symbolicLink }
        return switch openError {
        case ENOENT, ENOTDIR: .missing
        case ELOOP: .symbolicLink
        // Sandbox denial (EPERM) and discretionary ACL denial (EACCES) both surface as
        // unreadable. Never invent a distinct "permission denied" path that would let
        // callers treat Powerbox-out-of-scope ancestors as recoverable missing leaves.
        case EPERM, EACCES: .unreadable
        default: .unreadable
        }
    }

    static func readAllBytes(
        descriptor: Int32,
        maximumByteCount: Int?,
        hooks: Hooks
    ) throws -> Data {
        let maximum = maximumByteCount.map { max(0, $0) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var chunkIndex = 0
        while maximum.map({ data.count < $0 }) ?? true {
            try checkCancellation()
            let requested = maximum.map { min(buffer.count, $0 - data.count) } ?? buffer.count
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requested)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw WorkspaceAnchoredFileSystemError.unreadable
            }
            data.append(contentsOf: buffer.prefix(count))
            hooks.emit(.readChunk(chunkIndex))
            chunkIndex += 1
        }
        try checkCancellation()
        return data
    }

    static func writeAllBytes(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try checkCancellation()
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw WorkspaceAnchoredFileSystemError.unreadable
                }
                guard count > 0 else { throw WorkspaceAnchoredFileSystemError.unreadable }
                offset += count
            }
        }
    }

    static func sha256Digest(descriptor: Int32) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var offset: off_t = 0
        while true {
            try checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.pread(descriptor, $0.baseAddress, $0.count, offset)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw WorkspaceAnchoredFileSystemError.unreadable
            }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += off_t(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func checkCancellation() throws {
        if !ignoresInheritedTaskCancellation, Task.isCancelled {
            throw WorkspaceAnchoredFileSystemError.cancelled
        }
    }

    static func normalizedError(_ error: Error) -> WorkspaceAnchoredFileSystemError {
        error as? WorkspaceAnchoredFileSystemError ?? .unreadable
    }
}
