import Darwin
import Foundation

extension WorkspaceAnchoredFileSystem {
    /// The directory that holds a write's temporary file and, after a swap, the displaced
    /// original until cleanup.
    ///
    /// Normally that is the destination's own parent (sibling staging), so publication is a
    /// same-directory `renameatx_np`. A file-only App Sandbox grant (Open panel or Finder "Open
    /// With") covers the file but refuses any new entry in its parent with `EPERM`, while it
    /// still permits a cross-directory `RENAME_SWAP` of the granted leaf. Only when the parent
    /// refuses the sibling create does the write stage in Foundation's item-replacement
    /// directory instead: that directory is captured as its own root authority and anchored
    /// by its own descriptor chain, and every staged-name operation goes through it.
    struct WriteStaging {
        let chain: DirectoryDescriptorChain
        let descriptor: Int32
        /// A location inside the staging directory; staged entries are its siblings.
        let anchor: WorkspaceFileSystemLocation
        let isSeparateDirectory: Bool

        static func sibling(
            of location: WorkspaceFileSystemLocation,
            chain: DirectoryDescriptorChain,
            parentDescriptor: Int32
        ) -> WriteStaging {
            WriteStaging(
                chain: chain,
                descriptor: parentDescriptor,
                anchor: location,
                isSeparateDirectory: false
            )
        }

        func location(named name: String) -> WorkspaceFileSystemLocation? {
            anchor.sibling(named: name)
        }

        /// Validates the destination chain and, for a separate staging directory, that it is
        /// still the directory its descriptors were anchored to.
        func validateNamespace(destination chain: DirectoryDescriptorChain) throws {
            try chain.validateNamespace()
            if isSeparateDirectory {
                try self.chain.validateNamespace()
            }
        }
    }

    struct WriteDestination {
        let location: WorkspaceFileSystemLocation
        let chain: DirectoryDescriptorChain
        let parentDescriptor: Int32
        let leaf: String
    }

    static func performWrite(
        _ data: Data,
        to location: WorkspaceFileSystemLocation,
        expectation: WorkspaceNoFollowFileWriteExpectation,
        chain: DirectoryDescriptorChain,
        parentDescriptor: Int32,
        leaf: String,
        hooks: Hooks
    ) throws -> WorkspaceFileWriteOutcome {
        let target: WriteTarget
        do {
            target = try openWriteTarget(
                parentDescriptor: parentDescriptor,
                leaf: leaf,
                expectation: expectation
            )
        } catch {
            return notCommitted(reason: normalizedError(error), artifactState: .none)
        }
        defer { closeWriteTarget(target) }
        let destination = WriteDestination(
            location: location,
            chain: chain,
            parentDescriptor: parentDescriptor,
            leaf: leaf
        )
        do {
            return try performStagedWrite(
                data,
                target: target,
                staging: .sibling(of: location, chain: chain, parentDescriptor: parentDescriptor),
                destination: destination,
                hooks: hooks
            )
        } catch is SiblingStagingRefused {
            do {
                return try withSeparateStaging(
                    for: location,
                    parentDescriptor: parentDescriptor,
                    hooks: hooks
                ) { staging in
                    try performStagedWrite(
                        data,
                        target: target,
                        staging: staging,
                        destination: destination,
                        hooks: hooks
                    )
                }
            } catch {
                return notCommitted(reason: normalizedError(error), artifactState: .none)
            }
        }
    }

    /// The destination parent refused a new sibling entry before anything was created.
    struct SiblingStagingRefused: Error {}

    static let separateStagingAnchorName = "staging"

    static func isSiblingStagingRefusal(_ code: Int32) -> Bool {
        code == EPERM || code == EACCES
    }

    /// Runs `body` with a separate staging directory for `location`, then removes that
    /// directory when the write left it empty. A directory that still holds a reported
    /// artifact is kept so its outcome location stays valid.
    static func withSeparateStaging<T>(
        for location: WorkspaceFileSystemLocation,
        parentDescriptor: Int32,
        hooks: Hooks,
        _ body: (WriteStaging) throws -> T
    ) throws -> T {
        let directoryURL: URL
        do {
            directoryURL = try hooks.itemReplacementDirectory(for: location.fileURL)
        } catch {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        let authority: WorkspaceFileSystemRootAuthority
        do {
            authority = try WorkspaceFileSystemRootAuthority(rootURL: directoryURL)
        } catch {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        // Never stage in (or later remove) the destination parent itself, the directory that
        // just refused the sibling.
        let parentIdentity = try directoryDescriptorIdentity(parentDescriptor)
        guard authority.physicalIdentity != parentIdentity else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        defer {
            removeEmptyStagingDirectory(
                at: authority.canonicalRootURL,
                identity: authority.physicalIdentity
            )
        }
        // Publication must stay one atomic rename on the destination's device, never a copy.
        guard authority.physicalIdentity.device == parentIdentity.device else {
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
        let anchor = try WorkspaceFileSystemLocation(
            rootAuthority: authority,
            relativePath: separateStagingAnchorName
        )
        return try withAnchoredParent(at: anchor, hooks: .production) { chain, descriptor, _ in
            hooks.emit(.separateStagingAnchored)
            return try body(WriteStaging(
                chain: chain,
                descriptor: descriptor,
                anchor: anchor,
                isSeparateDirectory: true
            ))
        }
    }

    /// `rmdir` only removes an empty directory, and only the one Foundation returned for this
    /// write, matched by identity. Failure is not an error: the directory lives in the app's
    /// temporary items, and any retained artifact inside it was already reported.
    private static func removeEmptyStagingDirectory(
        at url: URL,
        identity: WorkspaceFileSystemIdentity
    ) {
        guard let path = try? WorkspaceLiteralFileURL.absolutePath(of: url) else { return }
        var status = stat()
        guard path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              WorkspaceFileSystemIdentity(
                  device: UInt64(status.st_dev),
                  inode: UInt64(status.st_ino)
              ) == identity
        else {
            return
        }
        _ = path.withCString { Darwin.rmdir($0) }
    }

    /// `renameatx_np` between the staging directory and the destination parent. Sibling
    /// staging passes the same descriptor twice, which is the original same-directory rename.
    static func secureRename(
        from sourceDescriptor: Int32,
        _ source: String,
        to destinationDescriptor: Int32,
        _ destination: String,
        flags: UInt32
    ) -> Int32 {
        source.withCString { sourcePath in
            destination.withCString { destinationPath in
                Darwin.renameatx_np(
                    sourceDescriptor,
                    sourcePath,
                    destinationDescriptor,
                    destinationPath,
                    flags | UInt32(RENAME_NOFOLLOW_ANY)
                )
            }
        }
    }
}

extension WorkspaceAnchoredFileSystem.WriteCommitContext {
    /// The destination leaf itself, which lives in the destination parent.
    var destinationRemovalContext: WorkspaceAnchoredFileSystem.ArtifactRemovalContext {
        WorkspaceAnchoredFileSystem.ArtifactRemovalContext(
            chain: chain,
            parentDescriptor: parentDescriptor,
            hooks: hooks
        )
    }

    func validateNamespaces() throws {
        try staging.validateNamespace(destination: chain)
    }

    /// Exchanges the staged name with the destination leaf: publication, and its reversal.
    func swapStagedNameWithLeaf() -> Int32 {
        WorkspaceAnchoredFileSystem.secureRename(
            from: staging.descriptor,
            prepared.name,
            to: parentDescriptor,
            leaf,
            flags: UInt32(RENAME_SWAP)
        )
    }
}

extension WorkspaceAnchoredFileSystem.Hooks {
    func itemReplacementDirectory(for destinationURL: URL) throws -> URL {
        if let itemReplacementDirectoryProvider {
            return try itemReplacementDirectoryProvider(destinationURL)
        }
        return try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationURL,
            create: true
        )
    }
}
