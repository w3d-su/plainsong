import Darwin
import Foundation

extension WorkspaceAnchoredFileSystem {
    private struct FileTargetInspectionContext {
        let location: WorkspaceFileSystemLocation
        let chain: DirectoryDescriptorChain
        let parentDescriptor: Int32
        let leaf: String
        let canonicalParentURL: URL
        let parentIsCaseSensitive: Bool
        let hooks: Hooks
    }

    private struct LeafNameCandidates {
        var exact: String?
        var equivalent: [String] = []
    }

    /// Inspects the writer's exact target namespace without requiring content read permission.
    /// Existing leaves are sampled from the anchored parent entry; missing leaves retain the
    /// descriptor-derived parent spelling. The result is safe to compare with App session state.
    static func inspectFileTarget(
        _ location: WorkspaceFileSystemLocation,
        hooks: Hooks = .production
    ) throws -> WorkspaceNoFollowFileTargetInspection {
        try withAnchoredParent(at: location, hooks: hooks) { chain, parentDescriptor, leaf in
            try checkCancellation()
            let context = try FileTargetInspectionContext(
                location: location,
                chain: chain,
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                canonicalParentURL: WorkspaceFileSystemRootAuthority.descriptorURL(
                    parentDescriptor,
                    isDirectory: true
                ),
                parentIsCaseSensitive: directoryIsCaseSensitive(parentDescriptor),
                hooks: hooks
            )
            let entry: DirectoryEntryIdentity
            do {
                entry = try directoryEntryIdentity(
                    parentDescriptor: parentDescriptor,
                    component: leaf
                )
            } catch WorkspaceAnchoredFileSystemError.missing {
                return try missingFileTargetInspection(context)
            }
            return try existingFileTargetInspection(context, entry: entry)
        }
    }

    private static func missingFileTargetInspection(
        _ context: FileTargetInspectionContext
    ) throws -> WorkspaceNoFollowFileTargetInspection {
        try context.chain.validateNamespace()
        context.hooks.emit(.namespaceValidated)
        try validateMissingName(
            parentDescriptor: context.parentDescriptor,
            leaf: context.leaf
        )
        try context.chain.validateNamespace()
        context.hooks.emit(.postflight)
        try checkCancellation()
        try validateMissingName(
            parentDescriptor: context.parentDescriptor,
            leaf: context.leaf
        )
        try context.chain.validateNamespace()
        let canonicalParentURL = try revalidatedCanonicalParentURL(context)
        return try targetInspection(
            state: .missing,
            context: context,
            canonicalParentURL: canonicalParentURL,
            canonicalLeaf: context.leaf
        )
    }

    private static func existingFileTargetInspection(
        _ context: FileTargetInspectionContext,
        entry: DirectoryEntryIdentity
    ) throws -> WorkspaceNoFollowFileTargetInspection {
        guard entry.isRegularFile else {
            throw entry.fileType == S_IFLNK
                ? WorkspaceAnchoredFileSystemError.symbolicLink
                : WorkspaceAnchoredFileSystemError.notRegularFile
        }
        let canonicalLeaf = try canonicalLeafName(
            parentDescriptor: context.parentDescriptor,
            requestedLeaf: context.leaf,
            expectedEntry: entry
        )
        context.hooks.emit(.fileOpened)
        try context.chain.validateNamespace()
        context.hooks.emit(.namespaceValidated)
        try validateExistingNames(context, canonicalLeaf: canonicalLeaf, entry: entry)
        context.hooks.emit(.postflight)
        try checkCancellation()

        let finalEntry = try existingDirectoryEntry(
            parentDescriptor: context.parentDescriptor,
            leaf: context.leaf
        )
        guard finalEntry == entry else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        let finalCanonicalLeaf = try canonicalLeafName(
            parentDescriptor: context.parentDescriptor,
            requestedLeaf: context.leaf,
            expectedEntry: finalEntry
        )
        guard finalCanonicalLeaf.utf8.elementsEqual(canonicalLeaf.utf8) else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        try context.chain.validateNamespace()
        try validateExistingNames(
            context,
            canonicalLeaf: finalCanonicalLeaf,
            entry: finalEntry
        )
        let canonicalParentURL = try revalidatedCanonicalParentURL(context)
        return try targetInspection(
            state: .regular(finalEntry.identity),
            context: context,
            canonicalParentURL: canonicalParentURL,
            canonicalLeaf: finalCanonicalLeaf
        )
    }

    private static func validateExistingNames(
        _ context: FileTargetInspectionContext,
        canonicalLeaf: String,
        entry: DirectoryEntryIdentity
    ) throws {
        try validateNameStillReferencesEntry(
            parentDescriptor: context.parentDescriptor,
            leaf: context.leaf,
            entry: entry
        )
        try validateNameStillReferencesEntry(
            parentDescriptor: context.parentDescriptor,
            leaf: canonicalLeaf,
            entry: entry
        )
        try context.chain.validateNamespace()
    }

    private static func revalidatedCanonicalParentURL(
        _ context: FileTargetInspectionContext
    ) throws -> URL {
        let finalURL = try WorkspaceFileSystemRootAuthority.descriptorURL(
            context.parentDescriptor,
            isDirectory: true
        )
        guard WorkspaceLiteralFileURL.pathBytesMatch(finalURL, context.canonicalParentURL)
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        return finalURL
    }

    private static func targetInspection(
        state: WorkspaceNoFollowFileTargetState,
        context: FileTargetInspectionContext,
        canonicalParentURL: URL,
        canonicalLeaf: String
    ) throws -> WorkspaceNoFollowFileTargetInspection {
        // Deliberately does not combine `canonicalParentURL` and `canonicalLeaf` via
        // `appendingPathComponent`: that call decomposes precomposed Unicode (NFC) in the leaf
        // into decomposed form (NFD) via CoreFoundation's file-system-representation bridging,
        // independent of and in addition to the `standardizedFileURL` corruption this same
        // family of functions must avoid. The leaf is joined at the string level instead.
        let canonicalRelativePath = try context.location.rootAuthority
            .relativePath(forCanonicalDescriptorParentURL: canonicalParentURL, leaf: canonicalLeaf)
        return try WorkspaceNoFollowFileTargetInspection(
            state: state,
            canonicalLocation: context.location.rootAuthority.location(
                relativePath: canonicalRelativePath
            ),
            parentIsCaseSensitive: context.parentIsCaseSensitive
        )
    }

    static func directoryIsCaseSensitive(_ descriptor: Int32) throws -> Bool {
        errno = 0
        let value = Darwin.fpathconf(descriptor, _PC_CASE_SENSITIVE)
        guard value >= 0 else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        return value != 0
    }

    private static func canonicalLeafName(
        parentDescriptor: Int32,
        requestedLeaf: String,
        expectedEntry: DirectoryEntryIdentity
    ) throws -> String {
        let candidates = try leafNameCandidates(
            parentDescriptor: parentDescriptor,
            requestedLeaf: requestedLeaf
        )
        if let exact = candidates.exact {
            guard try existingDirectoryEntry(
                parentDescriptor: parentDescriptor,
                leaf: exact
            ) == expectedEntry else {
                throw WorkspaceAnchoredFileSystemError.namespaceChanged
            }
            return exact
        }

        var matchingNames: [String] = []
        for name in candidates.equivalent {
            guard try existingDirectoryEntry(
                parentDescriptor: parentDescriptor,
                leaf: name
            ) == expectedEntry else { continue }
            matchingNames.append(name)
        }
        guard matchingNames.count == 1, let matchingName = matchingNames.first else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        return matchingName
    }

    /// Returns only an entry whose directory spelling is byte-for-byte equal to `leaf`.
    /// `fstatat` alone is insufficient on case/normalization-insensitive filesystems because
    /// an equivalent spelling can resolve to the same inode even when that literal name is absent.
    static func exactDirectoryEntry(
        parentDescriptor: Int32,
        leaf: String
    ) throws -> DirectoryEntryIdentity? {
        let candidates = try leafNameCandidates(
            parentDescriptor: parentDescriptor,
            requestedLeaf: leaf
        )
        guard let exact = candidates.exact else { return nil }
        return try existingDirectoryEntry(
            parentDescriptor: parentDescriptor,
            leaf: exact
        )
    }

    private static func existingDirectoryEntry(
        parentDescriptor: Int32,
        leaf: String
    ) throws -> DirectoryEntryIdentity {
        do {
            return try directoryEntryIdentity(
                parentDescriptor: parentDescriptor,
                component: leaf
            )
        } catch WorkspaceAnchoredFileSystemError.missing {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
    }

    private static func leafNameCandidates(
        parentDescriptor: Int32,
        requestedLeaf: String
    ) throws -> LeafNameCandidates {
        let enumerationDescriptor = Darwin.openat(
            parentDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard enumerationDescriptor >= 0 else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        defer { Darwin.closedir(directory) }

        var candidates = LeafNameCandidates()
        while let name = try nextDirectoryName(directory) {
            try checkCancellation()
            guard name != ".", name != ".." else { continue }
            if name.utf8.elementsEqual(requestedLeaf.utf8) {
                candidates.exact = name
            } else if name.compare(
                requestedLeaf,
                options: [.caseInsensitive]
            ) == .orderedSame {
                candidates.equivalent.append(name)
            }
        }
        return candidates
    }

    private static func nextDirectoryName(
        _ directory: UnsafeMutablePointer<DIR>
    ) throws -> String? {
        errno = 0
        guard let directoryEntry = Darwin.readdir(directory) else {
            guard errno == 0 else {
                throw WorkspaceAnchoredFileSystemError.unreadable
            }
            return nil
        }
        return withUnsafePointer(to: directoryEntry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: Int(MAXNAMLEN) + 1
            ) {
                String(cString: $0)
            }
        }
    }
}

extension WorkspaceFileSystemRootAuthority {
    /// Converts a descriptor-derived parent directory plus a literal leaf name into a
    /// root-relative path without asking Foundation to standardize a possibly missing final
    /// component or to combine the two path segments. Standardization can rewrite an existing
    /// `/private/var` root to `/var` while retaining `/private/var` for a missing child, which
    /// would make one descriptor-bound path appear outside its root; combining via
    /// `appendingPathComponent` separately decomposes precomposed Unicode (NFC) in `leaf` into
    /// decomposed form (NFD). The leaf is therefore joined at the string level instead.
    func relativePath(
        forCanonicalDescriptorParentURL parentURL: URL,
        leaf: String
    ) throws -> String {
        let rootPath = WorkspaceRootContainment.normalizedDirectoryPath(
            canonicalRootURL.path(percentEncoded: false)
        )
        let parentPath = WorkspaceRootContainment.normalizedDirectoryPath(
            parentURL.path(percentEncoded: false)
        )
        guard let parentRelativePath = WorkspaceLiteralFileURL.relativePath(
            of: parentPath,
            containedIn: rootPath
        )
        else {
            throw WorkspaceRootContainmentError.fileOutsideRoot
        }
        let relativePath = parentRelativePath.isEmpty ? leaf : "\(parentRelativePath)/\(leaf)"
        return try WorkspaceRootContainment.normalizedRelativePath(relativePath)
    }
}
