import Darwin
import Foundation

/// A lexical root-relative location permanently bound to one root authority.
public struct WorkspaceFileSystemLocation: Sendable, Hashable {
    public let rootAuthority: WorkspaceFileSystemRootAuthority
    public let relativePath: String
    public let fileURL: URL

    public var rootURL: URL {
        rootAuthority.canonicalRootURL
    }

    public var securityScopedURL: URL {
        rootAuthority.securityScopedURL
    }

    public init(
        rootURL: URL,
        relativePath: String,
        securityScopedURL: URL? = nil
    ) throws {
        try self.init(
            rootAuthority: WorkspaceFileSystemRootAuthority(
                rootURL: rootURL,
                securityScopedURL: securityScopedURL
            ),
            relativePath: relativePath
        )
    }

    /// Establishes standalone authority before the operation by anchoring the canonical
    /// parent and retaining the final filename as a no-follow lexical component.
    ///
    /// Deliberately does not route `fileURL` through `standardizedFileURL`: that call
    /// silently decomposes precomposed Unicode (NFC) into decomposed form (NFD) via
    /// CoreFoundation's file-system-representation bridging, which would corrupt an
    /// already-exact retained spelling on the round trip through this initializer.
    /// `lastPathComponent`/`deletingLastPathComponent()` read the URL's existing path
    /// bytes without that normalization. The parent is opened by root-authority capture,
    /// so descriptor-derived canonicalization follows aliases without first round-tripping
    /// its literal spelling through Foundation.
    public init(fileURL: URL) throws {
        let path = try WorkspaceLiteralFileURL.absolutePath(of: fileURL)
        let parentURL = try WorkspaceLiteralFileURL.fileURL(
            path: WorkspaceLiteralFileURL.parentPath(of: path),
            isDirectory: true
        )
        try self.init(
            rootAuthority: WorkspaceFileSystemRootAuthority(
                rootURL: parentURL,
                securityScopedURL: fileURL
            ),
            relativePath: WorkspaceLiteralFileURL.leafName(of: path)
        )
    }

    init(
        rootAuthority: WorkspaceFileSystemRootAuthority,
        relativePath: String
    ) throws {
        let relativePath = try WorkspaceRootContainment.normalizedRelativePath(relativePath)
        self.rootAuthority = rootAuthority
        self.relativePath = relativePath
        fileURL = Self.lexicalFileURL(
            rootURL: rootAuthority.canonicalRootURL,
            relativePath: relativePath
        )
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rootAuthority == rhs.rootAuthority
            && lhs.relativePath.utf8.elementsEqual(rhs.relativePath.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rootAuthority)
        for byte in relativePath.utf8 {
            hasher.combine(byte)
        }
    }

    func sibling(named name: String) -> WorkspaceFileSystemLocation? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        let parent = components.dropLast().map(String.init)
        return try? WorkspaceFileSystemLocation(
            rootAuthority: rootAuthority,
            relativePath: (parent + [name]).joined(separator: "/")
        )
    }

    private static func lexicalFileURL(rootURL: URL, relativePath: String) -> URL {
        let rootPath = WorkspaceRootContainment.normalizedDirectoryPath(
            rootURL.path(percentEncoded: false)
        )
        let path = rootPath == "/" ? "/\(relativePath)" : "\(rootPath)/\(relativePath)"
        return WorkspaceLiteralFileURL.fileURL(path: path, isDirectory: false)
    }
}

/// Builds and decomposes file URLs without asking Foundation to convert the path through a
/// filesystem representation. That conversion can normalize NFC to NFD, while descriptor-backed
/// authority must preserve the literal UTF-8 spelling that it captured or the caller supplied.
enum WorkspaceLiteralFileURL {
    /// Validates a user-visible URL before it crosses into a raw C-string path API. URL path
    /// access alone does not prove a file scheme, and an embedded NUL would truncate the path
    /// when passed to `open(2)`/`openat(2)`.
    static func absolutePath(of fileURL: URL) throws -> String {
        guard fileURL.isFileURL else {
            throw WorkspaceRootContainmentError.absolutePath(fileURL.absoluteString)
        }
        let path = fileURL.path(percentEncoded: false)
        guard path.hasPrefix("/") else {
            throw WorkspaceRootContainmentError.absolutePath(path)
        }
        guard !path.utf8.contains(0) else {
            throw WorkspaceRootContainmentError.traversal(path)
        }
        return path
    }

    static func fileURL(path: String, isDirectory: Bool) -> URL {
        precondition(path.hasPrefix("/"), "Filesystem URL paths must be absolute")
        precondition(!path.utf8.contains(0), "Filesystem URL paths may not contain NUL")

        let encodedPath = path.utf8.map { byte -> String in
            switch byte {
            case 0x2D, 0x2E, 0x2F, 0x30 ... 0x39, 0x41 ... 0x5A, 0x5F, 0x61 ... 0x7A, 0x7E:
                String(UnicodeScalar(byte))
            default:
                String(format: "%%%02X", byte)
            }
        }.joined()
        let directorySuffix = isDirectory && path != "/" && !path.hasSuffix("/") ? "/" : ""
        guard let url = URL(string: "file://\(encodedPath)\(directorySuffix)") else {
            preconditionFailure("Validated filesystem path could not form a lexical file URL")
        }
        return url
    }

    static func parentPath(of path: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw WorkspaceRootContainmentError.absolutePath(path)
        }
        let trimmedPath = WorkspaceRootContainment.normalizedDirectoryPath(path)
        guard let separator = trimmedPath.lastIndex(of: "/") else {
            throw WorkspaceRootContainmentError.absolutePath(path)
        }
        return separator == trimmedPath.startIndex ? "/" : String(trimmedPath[..<separator])
    }

    static func leafName(of path: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw WorkspaceRootContainmentError.absolutePath(path)
        }
        let trimmedPath = WorkspaceRootContainment.normalizedDirectoryPath(path)
        guard let separator = trimmedPath.lastIndex(of: "/"), separator != trimmedPath.endIndex else {
            throw WorkspaceRootContainmentError.emptyRelativePath
        }
        let leaf = String(trimmedPath[trimmedPath.index(after: separator)...])
        guard !leaf.isEmpty else {
            throw WorkspaceRootContainmentError.emptyRelativePath
        }
        return leaf
    }

    static func pathBytesMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.isFileURL, rhs.isFileURL else { return false }
        return lhs.path(percentEncoded: false).utf8.elementsEqual(rhs.path(percentEncoded: false).utf8)
    }

    /// Returns the literal root-relative spelling for an absolute child path, or `nil` when the
    /// child is not under the literal root. This deliberately compares each path component as
    /// UTF-8 bytes: Swift `String` equality and prefix APIs canonical-equate NFC and NFD, which
    /// would let a visually equivalent sibling cross a descriptor-authority containment check.
    /// An equal child and root is represented as the empty relative path.
    static func relativePath(of childPath: String, containedIn rootPath: String) -> String? {
        guard childPath.utf8.first == 0x2F, rootPath.utf8.first == 0x2F else {
            return nil
        }
        let childComponents = literalPathComponents(childPath)
        let rootComponents = literalPathComponents(rootPath)
        guard childComponents.count >= rootComponents.count,
              zip(childComponents, rootComponents).allSatisfy({
                  $0.utf8.elementsEqual($1.utf8)
              })
        else {
            return nil
        }
        return childComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func literalPathComponents(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }
}

public enum WorkspaceAnchoredFileSystemError: Error, Sendable, Equatable {
    case missing
    case symbolicLink
    case notRegularFile
    case unreadable
    case changedIdentity
    case changedContent
    case namespaceChanged
    case unstable
    case durabilityFailed
    case cleanupFailed
    case cancelled
}

public enum WorkspaceNoFollowFileWriteExpectation: Sendable, Equatable {
    case existing(WorkspaceFileSystemIdentity)
    case existingContent(WorkspaceFileSystemIdentity, sha256Digest: String)
    case missing
    case existingOrMissing
}

public enum WorkspaceFileWriteArtifactState: Sendable, Equatable {
    case none
    case retained(WorkspaceFileSystemLocation)
    case removalIndeterminate(WorkspaceFileSystemLocation)
}

public struct WorkspaceNotCommittedFileWrite: Sendable, Equatable {
    public let reason: WorkspaceAnchoredFileSystemError
    public let artifactState: WorkspaceFileWriteArtifactState
    public let retainedArtifactIdentity: WorkspaceFileSystemIdentity?

    public init(
        reason: WorkspaceAnchoredFileSystemError,
        artifactState: WorkspaceFileWriteArtifactState,
        retainedArtifactIdentity: WorkspaceFileSystemIdentity? = nil
    ) {
        self.reason = reason
        self.artifactState = artifactState
        self.retainedArtifactIdentity = retainedArtifactIdentity
    }
}

public struct WorkspaceDurableFileWrite: Sendable, Equatable {
    public let metadata: WorkspaceCoherentFileMetadata
    public let cleanupState: WorkspaceFileWriteArtifactState

    public init(
        metadata: WorkspaceCoherentFileMetadata,
        cleanupState: WorkspaceFileWriteArtifactState
    ) {
        self.metadata = metadata
        self.cleanupState = cleanupState
    }
}

public struct WorkspaceIndeterminateFileWrite: Sendable, Equatable {
    public let reason: WorkspaceAnchoredFileSystemError
    public let preparedMetadata: WorkspaceCoherentFileMetadata?
    public let recoveryArtifact: WorkspaceFileWriteArtifactState

    public init(
        reason: WorkspaceAnchoredFileSystemError,
        preparedMetadata: WorkspaceCoherentFileMetadata?,
        recoveryArtifact: WorkspaceFileWriteArtifactState
    ) {
        self.reason = reason
        self.preparedMetadata = preparedMetadata
        self.recoveryArtifact = recoveryArtifact
    }
}

/// The three states callers must arbitrate explicitly after a transactional write.
public enum WorkspaceFileWriteOutcome: Sendable, Equatable {
    case notCommitted(WorkspaceNotCommittedFileWrite)
    case committedAndDurable(WorkspaceDurableFileWrite)
    case committedButIndeterminate(WorkspaceIndeterminateFileWrite)
}

public enum WorkspaceNoFollowFileWriter {
    @discardableResult
    public static func write(
        _ data: Data,
        to location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation
    ) -> WorkspaceFileWriteOutcome {
        WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
            WorkspaceAnchoredFileSystem.write(
                data,
                to: location,
                expecting: expectation,
                hooks: .production
            )
        }
    }

    @discardableResult
    public static func write(
        text: String,
        to location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation
    ) -> WorkspaceFileWriteOutcome {
        write(Data(text.utf8), to: location, expecting: expectation)
    }

    @discardableResult
    static func write(
        _ data: Data,
        to location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation,
        hooks: WorkspaceAnchoredFileSystem.Hooks
    ) -> WorkspaceFileWriteOutcome {
        WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
            WorkspaceAnchoredFileSystem.write(
                data,
                to: location,
                expecting: expectation,
                hooks: hooks
            )
        }
    }
}

enum WorkspaceAnchoredFileSystem {
    @TaskLocal static var ignoresInheritedTaskCancellation = false

    enum CommitKind: Equatable {
        case swap
        case exclusiveCreate
    }

    enum Event: Equatable {
        case rootAnchored
        case componentOpened(String)
        case parentAnchored
        case namespaceValidated
        case fileOpened
        case temporaryFileCreated
        case temporaryFilePrepared
        case willCommit(CommitKind)
        case didCommit(CommitKind)
        case displacedEntryCaptured
        case willRollback
        case didRollback
        case readChunk(Int)
        case bytesRead
        case postflight
    }

    enum InjectedCall: Hashable {
        case renameSwap
        case renameExclusive
        case afterRenameSwap
        case afterRenameExclusive
        case captureDisplacedEntry
        case validateCommittedLeaf
        case syncCommittedDirectory
        case unlinkRollbackArtifact
        case syncCleanupDirectory
        case renameRollback
        case renameRollbackAfterValidation
        case unlinkCreatedDestination
        case syncRollbackDirectory
        case cleanupTemporary
        case renameQuarantinedArtifactAfterValidation
        case unlinkQuarantinedArtifact
        case unlinkQuarantinedArtifactAfterValidation
    }

    struct Hooks {
        static let production = Hooks()

        let eventHandler: (@Sendable (Event) -> Void)?
        let injectedFailure: (@Sendable (InjectedCall) -> WorkspaceAnchoredFileSystemError?)?

        init(
            eventHandler: (@Sendable (Event) -> Void)? = nil,
            injectedFailure: (@Sendable (InjectedCall) -> WorkspaceAnchoredFileSystemError?)? = nil
        ) {
            self.eventHandler = eventHandler
            self.injectedFailure = injectedFailure
        }

        func emit(_ event: Event) {
            eventHandler?(event)
        }

        func check(_ call: InjectedCall) throws {
            if let error = injectedFailure?(call) {
                throw error
            }
        }
    }

    struct ReadResult {
        let data: Data
        let metadata: WorkspaceCoherentFileMetadata
    }

    static func withSecurityScopedAccess<T>(
        to location: WorkspaceFileSystemLocation,
        _ body: () throws -> T
    ) rethrows -> T {
        try SecurityScopedAccess.withAccess(to: location.securityScopedURL, body)
    }

    static func validate(
        _ location: WorkspaceFileSystemLocation,
        hooks: Hooks = .production
    ) throws -> WorkspaceCoherentFileMetadata {
        try withAnchoredParent(at: location, hooks: hooks) { chain, parentDescriptor, leaf in
            try checkCancellation()
            let descriptor = try openFile(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            hooks.emit(.fileOpened)
            defer { Darwin.close(descriptor) }
            let metadata = try regularFileMetadata(descriptor: descriptor)
            try chain.validateNamespace()
            hooks.emit(.namespaceValidated)
            try validateNameStillReferencesDescriptor(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                metadata: metadata
            )
            try chain.validateNamespace()
            hooks.emit(.postflight)
            let finalMetadata = try regularFileMetadata(descriptor: descriptor)
            try chain.validateNamespace()
            try validateNameStillReferencesDescriptor(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                metadata: finalMetadata
            )
            try chain.validateNamespace()
            return finalMetadata
        }
    }

    static func read(
        _ location: WorkspaceFileSystemLocation,
        maximumByteCount: Int?,
        hooks: Hooks = .production
    ) throws -> ReadResult {
        try withAnchoredParent(at: location, hooks: hooks) { chain, parentDescriptor, leaf in
            try checkCancellation()
            let descriptor = try openFile(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            hooks.emit(.fileOpened)
            defer { Darwin.close(descriptor) }

            let before = try regularFileMetadata(descriptor: descriptor)
            let data = try readAllBytes(
                descriptor: descriptor,
                maximumByteCount: maximumByteCount,
                hooks: hooks
            )
            hooks.emit(.bytesRead)
            let after = try regularFileMetadata(descriptor: descriptor)
            try chain.validateNamespace()
            hooks.emit(.namespaceValidated)
            try validateNameStillReferencesDescriptor(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                metadata: after
            )
            try chain.validateNamespace()

            guard before == after else { throw WorkspaceAnchoredFileSystemError.unstable }
            if maximumByteCount == nil, after.byteCount != Int64(data.count) {
                throw WorkspaceAnchoredFileSystemError.unstable
            }
            hooks.emit(.postflight)
            try chain.validateNamespace()
            try validateNameStillReferencesDescriptor(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                metadata: after
            )
            try chain.validateNamespace()
            let finalMetadata = try regularFileMetadata(descriptor: descriptor)
            guard after == finalMetadata else { throw WorkspaceAnchoredFileSystemError.unstable }
            try chain.validateNamespace()
            try validateNameStillReferencesDescriptor(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                metadata: finalMetadata
            )
            try chain.validateNamespace()
            return ReadResult(data: data, metadata: finalMetadata)
        }
    }
}
