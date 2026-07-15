import Darwin
import Foundation
import WorkspaceKit

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

    deinit {
        Darwin.close(documentDescriptor)
    }

    var rootAuthority: WorkspaceFileSystemRootAuthority {
        location.rootAuthority
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
