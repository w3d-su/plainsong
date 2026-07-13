import Darwin
import Foundation

/// One immutable filesystem namespace authority captured before an operation begins.
///
/// Capture opens the selected directory exactly once, samples identity from that descriptor,
/// derives the canonical spelling from the same descriptor, and verifies that spelling still
/// names it. The retained descriptor keeps the physical identity alive for the value's lifetime;
/// equality and hashing use only the stable path/identity pair, never the descriptor integer.
public struct WorkspaceFileSystemRootAuthority: Sendable, Hashable {
    enum CaptureEvent: Equatable {
        case selectedRootOpened
        case identitySampled
        case canonicalPathDerived
        case canonicalPathVerified
    }

    struct CaptureHooks {
        static let production = CaptureHooks()

        let eventHandler: (@Sendable (CaptureEvent) -> Void)?

        init(eventHandler: (@Sendable (CaptureEvent) -> Void)? = nil) {
            self.eventHandler = eventHandler
        }

        func emit(_ event: CaptureEvent) {
            eventHandler?(event)
        }
    }

    public let canonicalRootURL: URL
    public let originalRootURL: URL
    public let securityScopedURL: URL
    let physicalIdentity: WorkspaceFileSystemIdentity
    private let descriptorLifetime: WorkspaceRootDescriptorLifetime

    public init(rootURL: URL, securityScopedURL: URL? = nil) throws {
        try self.init(
            rootURL: rootURL,
            securityScopedURL: securityScopedURL,
            hooks: .production
        )
    }

    init(
        rootURL: URL,
        securityScopedURL: URL? = nil,
        hooks: CaptureHooks
    ) throws {
        let originalRootURL = rootURL.standardizedFileURL
        let scopedURL = (securityScopedURL ?? rootURL).standardizedFileURL
        let capture = try SecurityScopedAccess.withAccess(to: scopedURL) {
            try Self.captureDescriptor(rootURL: originalRootURL, hooks: hooks)
        }

        self.originalRootURL = originalRootURL
        self.securityScopedURL = scopedURL
        canonicalRootURL = capture.canonicalRootURL
        physicalIdentity = capture.identity
        descriptorLifetime = WorkspaceRootDescriptorLifetime(descriptor: capture.descriptor)
    }

    /// Runs descriptor-backed authority construction on a nonisolated utility task.
    public static func capture(
        rootURL: URL,
        securityScopedURL: URL? = nil
    ) async throws -> WorkspaceFileSystemRootAuthority {
        try await capture(
            rootURL: rootURL,
            securityScopedURL: securityScopedURL,
            hooks: .production
        )
    }

    static func capture(
        rootURL: URL,
        securityScopedURL: URL? = nil,
        hooks: CaptureHooks
    ) async throws -> WorkspaceFileSystemRootAuthority {
        try await withThrowingTaskGroup(of: WorkspaceFileSystemRootAuthority.self) { group in
            group.addTask(priority: .utility) {
                try WorkspaceFileSystemRootAuthority(
                    rootURL: rootURL,
                    securityScopedURL: securityScopedURL,
                    hooks: hooks
                )
            }
            defer { group.cancelAll() }
            guard let authority = try await group.next() else {
                throw CancellationError()
            }
            return authority
        }
    }

    public func location(relativePath: String) throws -> WorkspaceFileSystemLocation {
        try WorkspaceFileSystemLocation(rootAuthority: self, relativePath: relativePath)
    }

    public static func == (
        lhs: WorkspaceFileSystemRootAuthority,
        rhs: WorkspaceFileSystemRootAuthority
    ) -> Bool {
        lhs.canonicalRootURL == rhs.canonicalRootURL
            && lhs.physicalIdentity == rhs.physicalIdentity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalRootURL)
        hasher.combine(physicalIdentity)
    }

    /// Converts a file URL expressed under either spelling captured for this authority
    /// into its canonical root-relative path without performing filesystem work.
    public func relativePath(forFileURL fileURL: URL) throws -> String {
        let filePath = WorkspaceRootContainment.normalizedDirectoryPath(
            fileURL.standardizedFileURL.path(percentEncoded: false)
        )
        for rootURL in [canonicalRootURL, originalRootURL] {
            let rootPath = WorkspaceRootContainment.normalizedDirectoryPath(
                rootURL.standardizedFileURL.path(percentEncoded: false)
            )
            guard rootPath == "/" || filePath.hasPrefix("\(rootPath)/") else {
                continue
            }
            let relativePath = rootPath == "/"
                ? String(filePath.dropFirst())
                : String(filePath.dropFirst(rootPath.count + 1))
            return try WorkspaceRootContainment.normalizedRelativePath(relativePath)
        }
        throw WorkspaceRootContainmentError.fileOutsideRoot
    }

    /// Resolves one file URL through this retained authority and returns the exact canonical,
    /// no-follow location. Callers performing this work for UI state must invoke it off-main.
    public func canonicalizedLocation(
        forFileURL fileURL: URL
    ) throws -> WorkspaceFileSystemLocation {
        try canonicalizedLocation(relativePath: relativePath(forFileURL: fileURL))
    }

    /// Follows aliases once through the retained root descriptor, then returns a no-follow
    /// location for the exact canonical target under this same authority.
    func canonicalizedLocation(relativePath: String) throws -> WorkspaceFileSystemLocation {
        let normalizedPath = try WorkspaceRootContainment.normalizedRelativePath(relativePath)
        try validateCanonicalBinding()

        let descriptor = try descriptorLifetime.withDescriptor { rootDescriptor in
            let descriptor = normalizedPath.withCString {
                Darwin.openat(
                    rootDescriptor,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_NONBLOCK
                )
            }
            guard descriptor >= 0 else {
                throw Self.errorForFailedAliasOpen(
                    rootDescriptor: rootDescriptor,
                    relativePath: normalizedPath
                )
            }
            return descriptor
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        guard WorkspaceCoherentFileReader.isRegularFile(status) else {
            throw WorkspaceAnchoredFileSystemError.notRegularFile
        }
        let openedIdentity = WorkspaceFileSystemIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
        let canonicalFileURL = try Self.descriptorURL(descriptor, isDirectory: false)
        let canonicalRelativePath = try self.relativePath(forFileURL: canonicalFileURL)
        let location = try location(relativePath: canonicalRelativePath)
        let validatedMetadata = try WorkspaceAnchoredFileSystem.validate(location)
        guard validatedMetadata.identity == openedIdentity else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        return location
    }

    func validateCanonicalBinding() throws {
        let retainedIdentity = try descriptorLifetime.withDescriptor { descriptor in
            try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(descriptor)
        }
        guard retainedIdentity == physicalIdentity else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }

        let verificationDescriptor = try Self.openDirectory(
            at: canonicalRootURL,
            noFollow: true
        )
        defer { Darwin.close(verificationDescriptor) }
        let verificationIdentity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(
            verificationDescriptor
        )
        guard verificationIdentity == physicalIdentity,
              try Self.descriptorURL(verificationDescriptor, isDirectory: true) == canonicalRootURL
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
    }

    private struct DescriptorCapture {
        let descriptor: Int32
        let canonicalRootURL: URL
        let identity: WorkspaceFileSystemIdentity
    }

    private static func captureDescriptor(
        rootURL: URL,
        hooks: CaptureHooks
    ) throws -> DescriptorCapture {
        let descriptor = try openDirectory(at: rootURL, noFollow: false)
        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor {
                Darwin.close(descriptor)
            }
        }
        hooks.emit(.selectedRootOpened)

        let identity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(descriptor)
        hooks.emit(.identitySampled)
        let canonicalRootURL = try descriptorURL(descriptor, isDirectory: true)
        hooks.emit(.canonicalPathDerived)

        let verificationDescriptor = try openDirectory(at: canonicalRootURL, noFollow: true)
        defer { Darwin.close(verificationDescriptor) }
        let verificationIdentity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(
            verificationDescriptor
        )
        guard verificationIdentity == identity,
              try descriptorURL(verificationDescriptor, isDirectory: true) == canonicalRootURL
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        hooks.emit(.canonicalPathVerified)

        shouldCloseDescriptor = false
        return DescriptorCapture(
            descriptor: descriptor,
            canonicalRootURL: canonicalRootURL,
            identity: identity
        )
    }

    private static func openDirectory(at url: URL, noFollow: Bool) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (noFollow ? O_NOFOLLOW : 0)
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, flags)
        }
        guard descriptor >= 0 else {
            throw switch errno {
            case ENOENT: WorkspaceAnchoredFileSystemError.missing
            case ELOOP: WorkspaceAnchoredFileSystemError.symbolicLink
            case ENOTDIR: WorkspaceAnchoredFileSystemError.notRegularFile
            default: WorkspaceAnchoredFileSystemError.unreadable
            }
        }
        return descriptor
    }

    private static func descriptorURL(_ descriptor: Int32, isDirectory: Bool) throws -> URL {
        var information = vnode_fdinfowithpath()
        let result = Darwin.proc_pidfdinfo(
            Darwin.getpid(),
            descriptor,
            PROC_PIDFDVNODEPATHINFO,
            &information,
            Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        )
        guard result == MemoryLayout<vnode_fdinfowithpath>.size else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        let path = withUnsafePointer(to: &information.pvip.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        guard path.hasPrefix("/") else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        return URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    private static func errorForFailedAliasOpen(
        rootDescriptor: Int32,
        relativePath: String
    ) -> WorkspaceAnchoredFileSystemError {
        let openError = errno
        var status = stat()
        let inspection = relativePath.withCString {
            Darwin.fstatat(rootDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if inspection == 0, (status.st_mode & S_IFMT) == S_IFLNK {
            return .symbolicLink
        }
        return switch openError {
        case ENOENT, ENOTDIR: .missing
        case ELOOP: .symbolicLink
        default: .unreadable
        }
    }
}

private final class WorkspaceRootDescriptorLifetime: @unchecked Sendable {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }

    func withDescriptor<T>(_ body: (Int32) throws -> T) rethrows -> T {
        try body(descriptor)
    }
}
