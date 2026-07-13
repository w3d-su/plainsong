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

        init(
            directories: [Directory],
            rootIndex: Int,
            expectedRootIdentity: WorkspaceFileSystemIdentity
        ) {
            self.directories = directories
            self.rootIndex = rootIndex
            self.expectedRootIdentity = expectedRootIdentity
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
    }

    static func withAnchoredParent<T>(
        at location: WorkspaceFileSystemLocation,
        hooks: Hooks,
        _ body: (DirectoryDescriptorChain, Int32, String) throws -> T
    ) throws -> T {
        try checkCancellation()
        guard let expectedRootIdentity = location.rootAuthority.physicalIdentity else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }

        let slashDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard slashDescriptor >= 0 else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        let slashIdentity: WorkspaceFileSystemIdentity
        do {
            slashIdentity = try directoryDescriptorIdentity(slashDescriptor)
        } catch {
            Darwin.close(slashDescriptor)
            throw error
        }

        var openedDirectories = [DirectoryDescriptorChain.Directory(
            descriptor: slashDescriptor,
            componentFromParent: nil,
            identity: slashIdentity
        )]
        var shouldCloseOpenedDirectories = true
        defer {
            if shouldCloseOpenedDirectories {
                for directory in openedDirectories.reversed() {
                    Darwin.close(directory.descriptor)
                }
            }
        }
        let canonicalComponents = location.rootURL.pathComponents.filter { $0 != "/" }

        for component in canonicalComponents {
            try checkCancellation()
            let next = try openDirectory(
                parentDescriptor: openedDirectories[openedDirectories.count - 1].descriptor,
                component: component
            )
            do {
                let identity = try directoryDescriptorIdentity(next)
                let entry = try directoryEntryIdentity(
                    parentDescriptor: openedDirectories[openedDirectories.count - 1].descriptor,
                    component: component
                )
                guard entry.isDirectory, entry.identity == identity else {
                    throw WorkspaceAnchoredFileSystemError.changedIdentity
                }
                openedDirectories.append(.init(
                    descriptor: next,
                    componentFromParent: component,
                    identity: identity
                ))
            } catch {
                Darwin.close(next)
                throw error
            }
        }

        let rootIndex = openedDirectories.count - 1
        guard openedDirectories[rootIndex].identity == expectedRootIdentity else {
            throw WorkspaceAnchoredFileSystemError.changedIdentity
        }
        let chain = DirectoryDescriptorChain(
            directories: openedDirectories,
            rootIndex: rootIndex,
            expectedRootIdentity: expectedRootIdentity
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
