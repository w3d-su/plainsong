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
        // Keep the caller's literal URL spelling intact through the capture. The descriptor
        // establishes the canonical physical root below; `standardizedFileURL` would instead
        // normalize an NFC component to NFD before that authority proof even starts.
        _ = try WorkspaceLiteralFileURL.absolutePath(of: rootURL)
        let originalRootURL = rootURL
        let scopedURL = securityScopedURL ?? rootURL
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
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: WorkspaceFileSystemRootAuthority.self) { group in
            group.addTask(priority: .utility) {
                try Task.checkCancellation()
                do {
                    let authority = try WorkspaceFileSystemRootAuthority(
                        rootURL: rootURL,
                        securityScopedURL: securityScopedURL,
                        hooks: hooks
                    )
                    try Task.checkCancellation()
                    return authority
                } catch WorkspaceAnchoredFileSystemError.cancelled {
                    throw CancellationError()
                }
            }
            defer { group.cancelAll() }
            do {
                guard let authority = try await group.next() else {
                    throw CancellationError()
                }
                // If cancellation wins after construction, drop the live descriptor-backed value
                // by throwing instead of returning it; deinit closes the retained descriptor.
                try Task.checkCancellation()
                return authority
            } catch WorkspaceAnchoredFileSystemError.cancelled {
                throw CancellationError()
            }
        }
    }

    /// Proves that `selectedRootURL` still names this capture's physical root identity.
    ///
    /// Opens the selected spelling under the same follow policy as capture (not a fresh
    /// unrelated `realpath` authority and not a lexical URL comparison) and requires the
    /// opened identity to equal the retained physical identity. Also revalidates the
    /// canonical binding of the retained descriptor.
    public func proveSelectedSpellingNamesCapturedIdentity(
        selectedRootURL: URL
    ) throws {
        try WorkspaceAnchoredFileSystem.checkCancellation()
        try validateCanonicalBinding()
        try WorkspaceAnchoredFileSystem.checkCancellation()

        let descriptor = try Self.openDirectory(at: selectedRootURL, noFollow: false)
        defer { Darwin.close(descriptor) }
        let selectedIdentity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(
            descriptor
        )
        guard selectedIdentity == physicalIdentity else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        try WorkspaceAnchoredFileSystem.checkCancellation()
    }

    public func location(relativePath: String) throws -> WorkspaceFileSystemLocation {
        try WorkspaceFileSystemLocation(rootAuthority: self, relativePath: relativePath)
    }

    public static func == (
        lhs: WorkspaceFileSystemRootAuthority,
        rhs: WorkspaceFileSystemRootAuthority
    ) -> Bool {
        WorkspaceLiteralFileURL.pathBytesMatch(lhs.canonicalRootURL, rhs.canonicalRootURL)
            && lhs.physicalIdentity == rhs.physicalIdentity
    }

    public func hash(into hasher: inout Hasher) {
        for byte in canonicalRootURL.path(percentEncoded: false).utf8 {
            hasher.combine(byte)
        }
        hasher.combine(physicalIdentity)
    }

    /// Converts a file URL expressed under either spelling captured for this authority
    /// into its canonical root-relative path without performing filesystem work.
    ///
    /// Reads `fileURL.path(percentEncoded: false)` directly rather than routing through
    /// `standardizedFileURL`, which silently decomposes precomposed Unicode (NFC) into
    /// decomposed form (NFD) via CoreFoundation's file-system-representation bridging. A
    /// retained lexical URL fed back through this function must reproduce its exact bytes;
    /// component-wise splitting on `/` still rejects `..`/collapses `.` via
    /// `normalizedRelativePath` and tolerates redundant slashes without touching Unicode.
    public func relativePath(forFileURL fileURL: URL) throws -> String {
        let fileComponents = try Self.literalPathComponents(
            WorkspaceLiteralFileURL.absolutePath(of: fileURL)
        )
        let matchingRootComponents = [canonicalRootURL, originalRootURL]
            .map { Self.literalPathComponents($0.path(percentEncoded: false)) }
            .filter { rootComponents in
                fileComponents.count > rootComponents.count
                    && zip(fileComponents, rootComponents).allSatisfy {
                        $0.utf8.elementsEqual($1.utf8)
                    }
            }
        guard let longestRootComponents = matchingRootComponents.max(by: {
            $0.count < $1.count
        }) else {
            throw WorkspaceRootContainmentError.fileOutsideRoot
        }

        let relativePath = fileComponents.dropFirst(longestRootComponents.count)
            .joined(separator: "/")
        return try WorkspaceRootContainment.normalizedRelativePath(relativePath)
    }

    private static func literalPathComponents(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
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
        try WorkspaceAnchoredFileSystem.checkCancellation()
        let retainedIdentity = try descriptorLifetime.withDescriptor { descriptor in
            try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(descriptor)
        }
        guard retainedIdentity == physicalIdentity else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }

        // Post-capture root-binding loss/replacement is always namespaceChanged. Leaf-level
        // missing/symlink/unreadable must not leak from reopening the canonical root spelling.
        do {
            try WorkspaceAnchoredFileSystem.checkCancellation()
            let verificationDescriptor = try Self.openDirectory(
                at: canonicalRootURL,
                noFollow: true
            )
            defer { Darwin.close(verificationDescriptor) }
            let verificationIdentity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(
                verificationDescriptor
            )
            guard verificationIdentity == physicalIdentity,
                  try WorkspaceLiteralFileURL.pathBytesMatch(
                      Self.descriptorURL(verificationDescriptor, isDirectory: true),
                      canonicalRootURL
                  )
            else {
                throw WorkspaceAnchoredFileSystemError.namespaceChanged
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch WorkspaceAnchoredFileSystemError.cancelled {
            throw WorkspaceAnchoredFileSystemError.cancelled
        } catch WorkspaceAnchoredFileSystemError.namespaceChanged {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        } catch {
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
        // Respects `ignoresInheritedTaskCancellation` so the legacy URL save facade can finish
        // a transaction when its scheduling task is already cancelled. Async `capture(...)`
        // still cancels cooperatively via explicit `Task.checkCancellation` around the group.
        try WorkspaceAnchoredFileSystem.checkCancellation()
        let descriptor = try openDirectory(at: rootURL, noFollow: false)
        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor {
                Darwin.close(descriptor)
            }
        }
        hooks.emit(.selectedRootOpened)
        try WorkspaceAnchoredFileSystem.checkCancellation()

        let identity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(descriptor)
        hooks.emit(.identitySampled)
        try WorkspaceAnchoredFileSystem.checkCancellation()
        let canonicalRootURL = try descriptorURL(descriptor, isDirectory: true)
        hooks.emit(.canonicalPathDerived)
        try WorkspaceAnchoredFileSystem.checkCancellation()

        let verificationDescriptor = try openDirectory(at: canonicalRootURL, noFollow: true)
        defer { Darwin.close(verificationDescriptor) }
        let verificationIdentity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(
            verificationDescriptor
        )
        guard verificationIdentity == identity,
              try WorkspaceLiteralFileURL.pathBytesMatch(
                  descriptorURL(verificationDescriptor, isDirectory: true),
                  canonicalRootURL
              )
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        hooks.emit(.canonicalPathVerified)
        try WorkspaceAnchoredFileSystem.checkCancellation()

        shouldCloseDescriptor = false
        return DescriptorCapture(
            descriptor: descriptor,
            canonicalRootURL: canonicalRootURL,
            identity: identity
        )
    }

    private static func openDirectory(at url: URL, noFollow: Bool) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (noFollow ? O_NOFOLLOW : 0)
        let path = try WorkspaceLiteralFileURL.absolutePath(of: url)
        let descriptor = path.withCString { path -> Int32 in
            Darwin.open(path, flags)
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

    static func descriptorURL(_ descriptor: Int32, isDirectory: Bool) throws -> URL {
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
        return WorkspaceLiteralFileURL.fileURL(path: path, isDirectory: isDirectory)
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
