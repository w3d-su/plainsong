import Darwin
import Foundation
import WorkspaceKit

/// A document-directory authority captured before the file bytes that authorize a binding are
/// loaded. The load must prove it read this exact leaf identity, then revalidate the namespace
/// before the pair can be published to App state.
struct PreparedEditorImageAssetDocumentAuthority: @unchecked Sendable {
    let location: WorkspaceFileSystemLocation
    let identity: WorkspaceFileSystemIdentity
    let authority: EditorImageAssetDocumentAuthority

    func matches(
        location candidateLocation: WorkspaceFileSystemLocation,
        identity candidateIdentity: WorkspaceFileSystemIdentity
    ) -> Bool {
        location == candidateLocation && identity == candidateIdentity
    }

    func validateLoadedIdentityAndNamespace(
        _ loadedIdentity: WorkspaceFileSystemIdentity
    ) throws {
        guard loadedIdentity == identity else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        try authority.validateNamespaceBinding()
    }
}

struct PreparedEditorImageAssetDocumentRead: @unchecked Sendable {
    let result: MarkdownFileReadResult
    let preparedAuthority: PreparedEditorImageAssetDocumentAuthority
}

/// A destination parent captured before a Save Copy writer enters the mutable namespace.
/// A durable result can acquire its new leaf only through this retained directory chain.
struct PreparedImageAssetDestinationAuthority: @unchecked Sendable {
    let location: WorkspaceFileSystemLocation
    private let directory: EditorImageAssetDirectoryLease
    private let leafName: String

    fileprivate init(
        location: WorkspaceFileSystemLocation,
        directory: EditorImageAssetDirectoryLease,
        leafName: String
    ) {
        self.location = location
        self.directory = directory
        self.leafName = leafName
    }

    func validateParentNamespaceBinding() throws {
        try SecurityScopedAccess.withAccess(to: location.securityScopedURL) {
            try directory.validateNamespaceBinding()
        }
    }

    func bindWrittenDocument(
        expectedIdentity: WorkspaceFileSystemIdentity
    ) throws -> PreparedEditorImageAssetDocumentAuthority {
        try SecurityScopedAccess.withAccess(to: location.securityScopedURL) {
            try directory.validateNamespaceBinding()
            let documentDescriptor = leafName.withCString {
                Darwin.openat(
                    directory.descriptor,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard documentDescriptor >= 0 else { throw editorImagePOSIXError() }

            do {
                guard try editorImageRegularFileIdentity(descriptor: documentDescriptor)
                    == expectedIdentity
                else {
                    throw WorkspaceAnchoredFileSystemError.namespaceChanged
                }
                try validateEditorImageRegularFileNamespaceEntry(
                    directoryDescriptor: directory.descriptor,
                    leafName: leafName,
                    expectedIdentity: expectedIdentity
                )
                try directory.validateNamespaceBinding()
                let authority = EditorImageAssetDocumentAuthority(
                    location: location,
                    identity: expectedIdentity,
                    directory: directory,
                    documentDescriptor: documentDescriptor,
                    leafName: leafName
                )
                return PreparedEditorImageAssetDocumentAuthority(
                    location: location,
                    identity: expectedIdentity,
                    authority: authority
                )
            } catch {
                Darwin.close(documentDescriptor)
                throw error
            }
        }
    }
}

func prepareEditorImageAssetDocumentDestinationAuthority(
    at location: WorkspaceFileSystemLocation
) throws -> PreparedImageAssetDestinationAuthority {
    try SecurityScopedAccess.withAccess(to: location.securityScopedURL) {
        let components = location.relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let leafName = components.last else {
            throw WorkspaceAnchoredFileSystemError.missing
        }
        let directory = try makeEditorImageDirectoryLease(
            rootAuthority: location.rootAuthority,
            directoryComponents: Array(components.dropLast()),
            createMissingFromIndex: nil
        )
        return PreparedImageAssetDestinationAuthority(
            location: location,
            directory: directory,
            leafName: leafName
        )
    }
}

func prepareEditorImageAssetDocumentAuthority(
    at location: WorkspaceFileSystemLocation,
    expecting expectedIdentity: WorkspaceFileSystemIdentity? = nil
) throws -> PreparedEditorImageAssetDocumentAuthority {
    try SecurityScopedAccess.withAccess(to: location.securityScopedURL) {
        let authority = try EditorImageAssetDocumentAuthority(
            location: location,
            expectedIdentity: expectedIdentity
        )
        return PreparedEditorImageAssetDocumentAuthority(
            location: location,
            identity: authority.identity,
            authority: authority
        )
    }
}

/// Captures the parent/leaf descriptor chain before loading, requires the coherent load to use
/// the captured leaf identity, and finally proves that the namespace still names that chain.
func prepareEditorImageAssetDocumentRead(
    fileStore: MarkdownFileStore,
    at location: WorkspaceFileSystemLocation,
    expecting expectedIdentity: WorkspaceFileSystemIdentity? = nil
) throws -> PreparedEditorImageAssetDocumentRead {
    try SecurityScopedAccess.withAccess(to: location.securityScopedURL) {
        let preparedAuthority = try prepareEditorImageAssetDocumentAuthority(
            at: location,
            expecting: expectedIdentity
        )
        let result = try fileStore.load(
            at: location,
            expecting: preparedAuthority.identity
        )
        try preparedAuthority.validateLoadedIdentityAndNamespace(
            result.metadata.identity
        )
        return PreparedEditorImageAssetDocumentRead(
            result: result,
            preparedAuthority: preparedAuthority
        )
    }
}

func validatePreparedEditorImageAssetDocumentAuthority(
    _ preparedAuthority: PreparedEditorImageAssetDocumentAuthority,
    loadedIdentity: WorkspaceFileSystemIdentity
) async -> Bool {
    await Task.detached(priority: .utility) {
        do {
            try SecurityScopedAccess.withAccess(
                to: preparedAuthority.location.securityScopedURL
            ) {
                try preparedAuthority.validateLoadedIdentityAndNamespace(
                    loadedIdentity
                )
            }
            return true
        } catch {
            return false
        }
    }.value
}

private struct EditorImageDirectoryDescriptorBinding {
    let descriptor: Int32
    let identity: WorkspaceFileSystemIdentity
    let componentFromParent: String?
}

final class EditorImageAssetDirectoryLease: @unchecked Sendable {
    let directoryURL: URL
    let rootAuthority: WorkspaceFileSystemRootAuthority
    private let bindings: [EditorImageDirectoryDescriptorBinding]

    var descriptor: Int32 {
        bindings[bindings.count - 1].descriptor
    }

    fileprivate init(
        bindings: [EditorImageDirectoryDescriptorBinding],
        directoryURL: URL,
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) {
        precondition(!bindings.isEmpty)
        self.bindings = bindings
        self.directoryURL = directoryURL
        self.rootAuthority = rootAuthority
    }

    deinit {
        for binding in bindings.reversed() {
            Darwin.close(binding.descriptor)
        }
    }

    func validateNamespaceBinding() throws {
        try rootAuthority.proveSelectedSpellingNamesCapturedIdentity(
            selectedRootURL: rootAuthority.originalRootURL
        )

        for (index, binding) in bindings.enumerated() {
            guard try editorImageDirectoryIdentity(descriptor: binding.descriptor)
                == binding.identity
            else {
                throw WorkspaceAnchoredFileSystemError.namespaceChanged
            }
            guard index > 0, let component = binding.componentFromParent else { continue }
            let parent = bindings[index - 1]
            guard try editorImageDirectoryIdentity(
                parentDescriptor: parent.descriptor,
                component: component
            ) == binding.identity else {
                throw WorkspaceAnchoredFileSystemError.namespaceChanged
            }
        }
    }

    func hasSameRetainedLineage(as other: EditorImageAssetDirectoryLease) -> Bool {
        guard rootAuthority == other.rootAuthority,
              bindings.count == other.bindings.count
        else {
            return false
        }
        return zip(bindings, other.bindings).allSatisfy { lhs, rhs in
            lhs.identity == rhs.identity
                && editorImagePathComponentMatchesExactly(
                    lhs.componentFromParent,
                    rhs.componentFromParent
                )
        }
    }
}

enum EditorImageAssetDiscardDisposition {
    case missing
    case workspaceChanged
    case preservedOriginal(EditorImageAssetPreservedLocation, reason: String)
    case preservedRecovery(EditorImageAssetPreservedLocation, reason: String)
    case preservedArtifacts(
        [EditorImageAssetPreservedArtifact],
        didChangeWorkspace: Bool
    )
}

struct EditorImageAssetPreservedArtifact {
    let location: EditorImageAssetPreservedLocation
    let reason: String
    let isRecovery: Bool
}

struct EditorImageAssetPreservedLocation {
    let currentPath: String?
    let identity: WorkspaceFileSystemIdentity?
    let leafNameHint: String

    var userFacingDescription: String {
        if let currentPath {
            return currentPath
        }
        let identityDescription = identity.map {
            "device \($0.device), inode \($0.inode)"
        } ?? "unknown identity"
        return "an unavailable visible path (\(identityDescription); leaf hint \(leafNameHint))"
    }
}

func editorImageAssetCleanupDescription(
    _ disposition: EditorImageAssetDiscardDisposition
) -> String? {
    switch disposition {
    case .missing, .workspaceChanged:
        nil
    case let .preservedOriginal(location, reason):
        "staging file preserved at \(location.userFacingDescription) (\(reason))"
    case let .preservedRecovery(location, reason):
        "staging file preserved at recovery location \(location.userFacingDescription) " +
            "(\(reason))"
    case let .preservedArtifacts(artifacts, _):
        artifacts.map { artifact in
            let qualifier = artifact.isRecovery ? " at recovery location" : ""
            return "staging file preserved\(qualifier) " +
                "\(artifact.location.userFacingDescription) (\(artifact.reason))"
        }.joined(separator: "; ")
    }
}

func editorImageAssetPreservedLocationForNamespaceEntry(
    directoryDescriptor: Int32,
    leafName: String,
    fallbackIdentity: WorkspaceFileSystemIdentity?
) -> EditorImageAssetPreservedLocation {
    // A supplied identity is provenance captured before this lookup. Never replace it with the
    // identity currently occupying the mutable leaf: doing so can report a later racer's path as
    // the location of the entry that cleanup actually acquired.
    let namespaceIdentity = fallbackIdentity ?? editorImageNamespaceEntryIdentity(
        directoryDescriptor: directoryDescriptor,
        leafName: leafName
    )
    let descriptor = leafName.withCString {
        Darwin.openat(
            directoryDescriptor,
            $0,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
    }
    guard descriptor >= 0 else {
        return EditorImageAssetPreservedLocation(
            currentPath: editorImageAssetVerifiedNamespaceEntryPath(
                directoryDescriptor: directoryDescriptor,
                leafName: leafName,
                expectedIdentity: namespaceIdentity
            ),
            identity: namespaceIdentity,
            leafNameHint: leafName
        )
    }
    defer { Darwin.close(descriptor) }
    let retained = editorImageAssetPreservedLocation(
        descriptor: descriptor,
        leafNameHint: leafName
    )
    if let fallbackIdentity,
       retained.identity != fallbackIdentity
    {
        return EditorImageAssetPreservedLocation(
            currentPath: nil,
            identity: fallbackIdentity,
            leafNameHint: leafName
        )
    }
    guard retained.currentPath == nil else { return retained }
    return EditorImageAssetPreservedLocation(
        currentPath: editorImageAssetVerifiedNamespaceEntryPath(
            directoryDescriptor: directoryDescriptor,
            leafName: leafName,
            expectedIdentity: namespaceIdentity ?? retained.identity
        ),
        identity: namespaceIdentity ?? retained.identity,
        leafNameHint: leafName
    )
}

func editorImageAssetPreservedLocation(
    descriptor: Int32,
    leafNameHint: String
) -> EditorImageAssetPreservedLocation {
    let identity = try? editorImageFileSystemIdentity(descriptor: descriptor)
    return EditorImageAssetPreservedLocation(
        currentPath: editorImageAssetVerifiedCurrentPath(
            descriptor: descriptor,
            expectedIdentity: identity
        ),
        identity: identity,
        leafNameHint: leafNameHint
    )
}

private func editorImageNamespaceEntryIdentity(
    directoryDescriptor: Int32,
    leafName: String
) -> WorkspaceFileSystemIdentity? {
    var status = stat()
    let result = leafName.withCString {
        Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else { return nil }
    return WorkspaceFileSystemIdentity(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino)
    )
}

private func editorImageAssetVerifiedNamespaceEntryPath(
    directoryDescriptor: Int32,
    leafName: String,
    expectedIdentity: WorkspaceFileSystemIdentity?
) -> String? {
    guard let expectedIdentity,
          let directoryIdentity = try? editorImageFileSystemIdentity(
              descriptor: directoryDescriptor
          ),
          let directoryPath = editorImageAssetVerifiedCurrentPath(
              descriptor: directoryDescriptor,
              expectedIdentity: directoryIdentity
          )
    else {
        return nil
    }
    let verificationDescriptor = directoryPath.withCString {
        Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
    }
    guard verificationDescriptor >= 0 else { return nil }
    defer { Darwin.close(verificationDescriptor) }
    guard editorImageNamespaceEntryIdentity(
        directoryDescriptor: verificationDescriptor,
        leafName: leafName
    ) == expectedIdentity else {
        return nil
    }
    return URL(fileURLWithPath: directoryPath, isDirectory: true)
        .appendingPathComponent(leafName, isDirectory: false)
        .path(percentEncoded: false)
}

func editorImageAssetPreservationName(for leafName: String) -> String {
    let pathExtension = (leafName as NSString).pathExtension
    let extensionSuffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
    return "Plainsong-preserved-\(UUID().uuidString)\(extensionSuffix)"
}

private func editorImageAssetVerifiedCurrentPath(
    descriptor: Int32,
    expectedIdentity: WorkspaceFileSystemIdentity?
) -> String? {
    guard let expectedIdentity else { return nil }
    var information = vnode_fdinfowithpath()
    let result = Darwin.proc_pidfdinfo(
        Darwin.getpid(),
        descriptor,
        PROC_PIDFDVNODEPATHINFO,
        &information,
        Int32(MemoryLayout<vnode_fdinfowithpath>.size)
    )
    guard result == MemoryLayout<vnode_fdinfowithpath>.size else { return nil }
    let path = withUnsafePointer(to: &information.pvip.vip_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
            String(cString: $0)
        }
    }
    guard path.hasPrefix("/") else { return nil }

    let verificationDescriptor = path.withCString {
        Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
    }
    guard verificationDescriptor >= 0 else { return nil }
    defer { Darwin.close(verificationDescriptor) }
    guard (try? editorImageFileSystemIdentity(descriptor: verificationDescriptor))
        == expectedIdentity
    else {
        return nil
    }
    return path
}

private func editorImageFileSystemIdentity(
    descriptor: Int32
) throws -> WorkspaceFileSystemIdentity {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
        throw WorkspaceAnchoredFileSystemError.namespaceChanged
    }
    return WorkspaceFileSystemIdentity(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino)
    )
}

final class EditorImageAssetDocumentAuthority: @unchecked Sendable {
    let location: WorkspaceFileSystemLocation
    let identity: WorkspaceFileSystemIdentity

    private let directory: EditorImageAssetDirectoryLease
    private let documentDescriptor: Int32
    private let leafName: String

    init(
        location: WorkspaceFileSystemLocation,
        expectedIdentity: WorkspaceFileSystemIdentity? = nil
    ) throws {
        let components = location.relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let leafName = components.last else {
            throw WorkspaceAnchoredFileSystemError.missing
        }
        let directory = try makeEditorImageDirectoryLease(
            rootAuthority: location.rootAuthority,
            directoryComponents: Array(components.dropLast()),
            createMissingFromIndex: nil
        )
        let documentDescriptor = leafName.withCString {
            Darwin.openat(
                directory.descriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard documentDescriptor >= 0 else { throw editorImagePOSIXError() }

        do {
            let identity = try editorImageRegularFileIdentity(
                descriptor: documentDescriptor
            )
            if let expectedIdentity, identity != expectedIdentity {
                throw WorkspaceAnchoredFileSystemError.namespaceChanged
            }
            try validateEditorImageRegularFileNamespaceEntry(
                directoryDescriptor: directory.descriptor,
                leafName: leafName,
                expectedIdentity: identity
            )
            self.location = location
            self.identity = identity
            self.directory = directory
            self.documentDescriptor = documentDescriptor
            self.leafName = leafName
        } catch {
            Darwin.close(documentDescriptor)
            throw error
        }
    }

    fileprivate init(
        location: WorkspaceFileSystemLocation,
        identity: WorkspaceFileSystemIdentity,
        directory: EditorImageAssetDirectoryLease,
        documentDescriptor: Int32,
        leafName: String
    ) {
        self.location = location
        self.identity = identity
        self.directory = directory
        self.documentDescriptor = documentDescriptor
        self.leafName = leafName
    }

    deinit {
        Darwin.close(documentDescriptor)
    }

    var rootAuthority: WorkspaceFileSystemRootAuthority {
        location.rootAuthority
    }

    var descriptor: Int32 {
        documentDescriptor
    }

    var currentDirectoryComponents: [String] {
        location.relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .dropLast()
            .map(String.init)
    }

    func validateNamespaceBinding() throws {
        try directory.validateNamespaceBinding()
        guard try editorImageRegularFileIdentity(descriptor: documentDescriptor) == identity else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        try validateEditorImageRegularFileNamespaceEntry(
            directoryDescriptor: directory.descriptor,
            leafName: leafName,
            expectedIdentity: identity
        )
    }

    func hasSameRetainedParentLineage(
        as other: EditorImageAssetDocumentAuthority
    ) -> Bool {
        directory.hasSameRetainedLineage(as: other.directory)
    }

    /// Rebinds an atomic-save replacement only through the already-retained parent descriptor.
    /// No URL component is resolved again, so a replacement parent cannot acquire authority.
    func rebindDocument(
        expectedIdentity: WorkspaceFileSystemIdentity
    ) throws -> EditorImageAssetDocumentAuthority {
        try directory.validateNamespaceBinding()
        let replacementDescriptor = leafName.withCString {
            Darwin.openat(
                directory.descriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard replacementDescriptor >= 0 else { throw editorImagePOSIXError() }

        do {
            guard try editorImageRegularFileIdentity(descriptor: replacementDescriptor)
                == expectedIdentity
            else {
                throw WorkspaceAnchoredFileSystemError.namespaceChanged
            }
            try validateEditorImageRegularFileNamespaceEntry(
                directoryDescriptor: directory.descriptor,
                leafName: leafName,
                expectedIdentity: expectedIdentity
            )
            try directory.validateNamespaceBinding()
            return EditorImageAssetDocumentAuthority(
                location: location,
                identity: expectedIdentity,
                directory: directory,
                documentDescriptor: replacementDescriptor,
                leafName: leafName
            )
        } catch {
            Darwin.close(replacementDescriptor)
            throw error
        }
    }
}

private func editorImagePathComponentMatchesExactly(
    _ lhs: String?,
    _ rhs: String?
) -> Bool {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        lhs.utf8.elementsEqual(rhs.utf8)
    case (nil, nil):
        true
    default:
        false
    }
}

func makeEditorImageDirectoryLease(
    rootAuthority: WorkspaceFileSystemRootAuthority,
    directoryComponents: [String],
    createMissingFromIndex: Int?
) throws -> EditorImageAssetDirectoryLease {
    try rootAuthority.proveSelectedSpellingNamesCapturedIdentity(
        selectedRootURL: rootAuthority.originalRootURL
    )
    let rootURL = rootAuthority.canonicalRootURL
    let rootDescriptor = Darwin.open(
        rootURL.path(percentEncoded: false),
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
    )
    guard rootDescriptor >= 0 else { throw editorImagePOSIXError() }

    var bindings = [EditorImageDirectoryDescriptorBinding]()
    var shouldCloseBindings = true
    defer {
        if shouldCloseBindings {
            for binding in bindings.reversed() {
                Darwin.close(binding.descriptor)
            }
        }
    }

    do {
        let verification = try WorkspaceFileSystemRootAuthority(
            rootURL: rootURL,
            securityScopedURL: rootAuthority.securityScopedURL
        )
        guard verification == rootAuthority else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        try bindings.append(EditorImageDirectoryDescriptorBinding(
            descriptor: rootDescriptor,
            identity: editorImageDirectoryIdentity(descriptor: rootDescriptor),
            componentFromParent: nil
        ))

        var directoryURL = rootURL
        for (index, component) in directoryComponents.enumerated() {
            let nextDescriptor = try openEditorImageDirectory(
                parentDescriptor: bindings[bindings.count - 1].descriptor,
                component: component,
                createIfMissing: createMissingFromIndex.map { index >= $0 } ?? false
            )
            do {
                try bindings.append(EditorImageDirectoryDescriptorBinding(
                    descriptor: nextDescriptor,
                    identity: editorImageDirectoryIdentity(descriptor: nextDescriptor),
                    componentFromParent: component
                ))
            } catch {
                Darwin.close(nextDescriptor)
                throw error
            }
            directoryURL.appendPathComponent(component, isDirectory: true)
        }

        shouldCloseBindings = false
        let lease = EditorImageAssetDirectoryLease(
            bindings: bindings,
            directoryURL: directoryURL,
            rootAuthority: rootAuthority
        )
        try lease.validateNamespaceBinding()
        return lease
    } catch {
        if bindings.isEmpty {
            Darwin.close(rootDescriptor)
        }
        throw error
    }
}

private func openEditorImageDirectory(
    parentDescriptor: Int32,
    component: String,
    createIfMissing: Bool
) throws -> Int32 {
    func open() -> Int32 {
        component.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
    }

    var descriptor = open()
    if descriptor < 0, errno == ENOENT, createIfMissing {
        let createResult = component.withCString {
            Darwin.mkdirat(
                parentDescriptor,
                $0,
                mode_t(S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
            )
        }
        guard createResult == 0 || errno == EEXIST else {
            throw editorImagePOSIXError()
        }
        descriptor = open()
    }
    guard descriptor >= 0 else { throw editorImagePOSIXError() }
    return descriptor
}

private func editorImageDirectoryIdentity(
    descriptor: Int32
) throws -> WorkspaceFileSystemIdentity {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFDIR
    else {
        throw WorkspaceAnchoredFileSystemError.namespaceChanged
    }
    return WorkspaceFileSystemIdentity(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino)
    )
}

private func editorImageDirectoryIdentity(
    parentDescriptor: Int32,
    component: String
) throws -> WorkspaceFileSystemIdentity {
    var status = stat()
    let result = component.withCString {
        Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
        throw WorkspaceAnchoredFileSystemError.namespaceChanged
    }
    return WorkspaceFileSystemIdentity(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino)
    )
}

private func editorImageRegularFileIdentity(
    descriptor: Int32
) throws -> WorkspaceFileSystemIdentity {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG
    else {
        throw WorkspaceAnchoredFileSystemError.namespaceChanged
    }
    return WorkspaceFileSystemIdentity(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino)
    )
}

private func validateEditorImageRegularFileNamespaceEntry(
    directoryDescriptor: Int32,
    leafName: String,
    expectedIdentity: WorkspaceFileSystemIdentity
) throws {
    var status = stat()
    let result = leafName.withCString {
        Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          WorkspaceFileSystemIdentity(
              device: UInt64(status.st_dev),
              inode: UInt64(status.st_ino)
          ) == expectedIdentity
    else {
        throw WorkspaceAnchoredFileSystemError.namespaceChanged
    }
}
