import Darwin
import Foundation

enum WorkspaceMutationRecoveryDurableFileStore {
    enum Event: Equatable {
        case directoryCreated(URL)
        case directorySynchronized(URL)
    }

    typealias EventHandler = (Event) -> Void
    typealias DescriptorSynchronizer = (Int32) -> Int32

    static func ensureDirectoryHierarchy(
        _ directoryURL: URL,
        existingHierarchyDurabilityBoundaryURL: URL? = nil,
        synchronizeExistingHierarchy: Bool = true,
        eventHandler: EventHandler? = nil,
        descriptorSynchronizer: DescriptorSynchronizer = { Darwin.fsync($0) }
    ) throws {
        let missingDirectories = try missingDirectoryHierarchy(
            endingAt: directoryURL
        )
        for missingDirectory in missingDirectories.reversed() {
            try publishDirectoryEdge(
                missingDirectory,
                finalDirectoryURL: directoryURL,
                eventHandler: eventHandler,
                descriptorSynchronizer: descriptorSynchronizer
            )
        }

        try requireDirectory(directoryURL)
        if missingDirectories.isEmpty {
            try setDirectoryPermissions(directoryURL, permissions: mode_t(0o700))
        }
        if synchronizeExistingHierarchy || !missingDirectories.isEmpty {
            for existingDirectory in try directoryHierarchy(
                from: directoryURL,
                through: existingHierarchyDurabilityBoundaryURL
            ) {
                try synchronizeDirectory(
                    existingDirectory,
                    eventHandler: eventHandler,
                    descriptorSynchronizer: descriptorSynchronizer
                )
            }
        }
    }

    static func write(
        _ data: Data,
        to destinationURL: URL,
        directoryURL: URL
    ) throws {
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor: Int32 = temporaryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }

        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                temporaryURL.withUnsafeFileSystemRepresentation { path in
                    if let path {
                        _ = Darwin.unlink(path)
                    }
                }
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, baseAddress, remaining)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { throw currentPOSIXError() }
                remaining -= written
                baseAddress = baseAddress.advanced(by: written)
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }

        let renameResult: Int32 = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else { throw currentPOSIXError() }
        shouldRemoveTemporary = false
        try synchronizeDirectory(directoryURL)
    }

    static func remove(
        _ destinationURL: URL,
        directoryURL: URL,
        eventHandler: EventHandler? = nil
    ) throws {
        let result: Int32 = destinationURL.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.unlink(path)
        }
        if result != 0 {
            guard errno == ENOENT else { throw currentPOSIXError() }
        }
        try synchronizeDirectory(directoryURL, eventHandler: eventHandler)
    }

    private static func requireDirectory(_ directoryURL: URL) throws {
        var status = stat()
        let result: Int32 = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else { throw currentPOSIXError() }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXError(.ENOTDIR)
        }
    }

    private static func missingDirectoryHierarchy(
        endingAt directoryURL: URL
    ) throws -> [URL] {
        var missingDirectories: [URL] = []
        var candidateURL = directoryURL
        while !directoryExists(candidateURL) {
            guard errno == ENOENT else { throw currentPOSIXError() }
            missingDirectories.append(candidateURL)
            let parentURL = candidateURL.deletingLastPathComponent()
            guard parentURL != candidateURL else {
                throw POSIXError(.ENOENT)
            }
            candidateURL = parentURL
        }
        return missingDirectories
    }

    private static func directoryExists(_ directoryURL: URL) -> Bool {
        var status = stat()
        let result: Int32 = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else { return false }
        if status.st_mode & S_IFMT != S_IFDIR {
            errno = ENOTDIR
            return false
        }
        return true
    }

    private static func publishDirectoryEdge(
        _ directoryURL: URL,
        finalDirectoryURL: URL,
        eventHandler: EventHandler?,
        descriptorSynchronizer: DescriptorSynchronizer
    ) throws {
        let created = try createDirectoryIfMissing(directoryURL)
        if created || directoryURL == finalDirectoryURL {
            try setDirectoryPermissions(
                directoryURL,
                permissions: mode_t(0o700)
            )
        }
        if created {
            eventHandler?(.directoryCreated(directoryURL))
        }
        try synchronizeDirectory(
            directoryURL,
            eventHandler: eventHandler,
            descriptorSynchronizer: descriptorSynchronizer
        )
        try synchronizeDirectory(
            directoryURL.deletingLastPathComponent(),
            eventHandler: eventHandler,
            descriptorSynchronizer: descriptorSynchronizer
        )
    }

    private static func directoryHierarchy(
        from directoryURL: URL,
        through boundaryURL: URL?
    ) throws -> [URL] {
        guard let boundaryURL else { return [directoryURL] }
        var hierarchy: [URL] = []
        var candidateURL = directoryURL
        while true {
            hierarchy.append(candidateURL)
            if candidateURL == boundaryURL {
                return hierarchy
            }
            let parentURL = candidateURL.deletingLastPathComponent()
            guard parentURL != candidateURL else {
                throw POSIXError(.EINVAL)
            }
            candidateURL = parentURL
        }
    }

    private static func createDirectoryIfMissing(
        _ directoryURL: URL
    ) throws -> Bool {
        let result: Int32 = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.mkdir(path, mode_t(0o700))
        }
        if result == 0 {
            return true
        }
        guard errno == EEXIST else { throw currentPOSIXError() }
        try requireDirectory(directoryURL)
        return false
    }

    private static func setDirectoryPermissions(
        _ directoryURL: URL,
        permissions: mode_t
    ) throws {
        let descriptor: Int32 = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, permissions) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func synchronizeDescriptor(
        _ descriptor: Int32,
        directoryURL: URL,
        eventHandler: EventHandler?,
        descriptorSynchronizer: DescriptorSynchronizer
    ) throws {
        guard descriptorSynchronizer(descriptor) == 0 else {
            throw currentPOSIXError()
        }
        eventHandler?(.directorySynchronized(directoryURL))
    }

    private static func synchronizeDirectory(
        _ directoryURL: URL,
        eventHandler: EventHandler? = nil,
        descriptorSynchronizer: DescriptorSynchronizer = { Darwin.fsync($0) }
    ) throws {
        let descriptor: Int32 = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        try synchronizeDescriptor(
            descriptor,
            directoryURL: directoryURL,
            eventHandler: eventHandler,
            descriptorSynchronizer: descriptorSynchronizer
        )
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

extension WorkspaceMutationRecoveryDurableFileStore {
    static func quarantineRecord(
        _ sourceURL: URL,
        as quarantineFilename: String,
        directoryURL: URL,
        eventHandler: EventHandler? = nil
    ) throws {
        let directoryDescriptor: Int32 =
            directoryURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(
                    path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
        guard directoryDescriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(directoryDescriptor) }

        let result = sourceURL.lastPathComponent.withCString { sourcePath in
            quarantineFilename.withCString { quarantinePath in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    sourcePath,
                    directoryDescriptor,
                    quarantinePath,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard result == 0 else { throw currentPOSIXError() }
        try synchronizeDescriptor(
            directoryDescriptor,
            directoryURL: directoryURL,
            eventHandler: eventHandler,
            descriptorSynchronizer: { Darwin.fsync($0) }
        )
    }

    @discardableResult
    static func quarantineRecoveryDirectory(
        _ directoryURL: URL,
        eventHandler: EventHandler? = nil,
        descriptorSynchronizer: DescriptorSynchronizer = { Darwin.fsync($0) }
    ) throws -> URL? {
        let parentURL = directoryURL.deletingLastPathComponent()
        let parentDescriptor: Int32 = parentURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(parentDescriptor) }

        let sourceName = directoryURL.lastPathComponent
        for _ in 0 ..< 32 {
            let quarantineName =
                "\(sourceName)-unreadable-\(UUID().uuidString.lowercased())"
            let result = sourceName.withCString { sourcePath in
                quarantineName.withCString { quarantinePath in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        sourcePath,
                        parentDescriptor,
                        quarantinePath,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            if result == 0 {
                try synchronizeDescriptor(
                    parentDescriptor,
                    directoryURL: parentURL,
                    eventHandler: eventHandler,
                    descriptorSynchronizer: descriptorSynchronizer
                )
                return parentURL.appendingPathComponent(
                    quarantineName,
                    isDirectory: true
                )
            }
            if errno == ENOENT {
                try synchronizeDescriptor(
                    parentDescriptor,
                    directoryURL: parentURL,
                    eventHandler: eventHandler,
                    descriptorSynchronizer: descriptorSynchronizer
                )
                return nil
            }
            guard errno == EEXIST else { throw currentPOSIXError() }
        }
        throw POSIXError(.EEXIST)
    }
}
