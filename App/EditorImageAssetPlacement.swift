import Darwin
import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

struct RetainedEditorImageAssetDocumentAuthority {
    let location: WorkspaceFileSystemLocation
    let identity: WorkspaceFileSystemIdentity
    let authority: EditorImageAssetDocumentAuthority

    func matches(
        location candidateLocation: WorkspaceFileSystemLocation,
        identity candidateIdentity: WorkspaceFileSystemIdentity
    ) -> Bool {
        location == candidateLocation && identity == candidateIdentity
    }

    init(_ prepared: PreparedEditorImageAssetDocumentAuthority) {
        location = prepared.location
        identity = prepared.identity
        authority = prepared.authority
    }
}

struct EditorImageAssetPlacement {
    let relativePaths: [String]
    let createdAssets: [CreatedEditorImageAsset]
    let documentAuthority: EditorImageAssetDocumentAuthority
    let retainedReferences: [RetainedEditorImageAssetReference]
}

enum EditorImageAssetPlacementEvent: Equatable {
    case willPublish(URL)
    case didRenameBeforeValidation(URL)
    case didPublish(URL)
    case didCaptureWorkspaceReference(URL)
}

typealias EditorImageAssetPlacementEventHandler = @Sendable (
    EditorImageAssetPlacementEvent
) throws -> Void

struct EditorImageAssetContentProof: Equatable {
    let identity: WorkspaceFileSystemIdentity
    let byteCount: Int64
    let sha256Digest: String
}

struct RetainedEditorImageAssetReference {
    let authority: EditorImageAssetDocumentAuthority
    let proof: EditorImageAssetContentProof
}

final class CreatedEditorImageAsset: @unchecked Sendable {
    let directory: EditorImageAssetDirectoryLease
    let descriptor: Int32
    let leafName: String
    let proof: EditorImageAssetContentProof

    private let lock = NSLock()
    private var isDiscardClaimed = false

    init(
        directory: EditorImageAssetDirectoryLease,
        descriptor: Int32,
        leafName: String,
        proof: EditorImageAssetContentProof
    ) {
        self.directory = directory
        self.descriptor = descriptor
        self.leafName = leafName
        self.proof = proof
    }

    deinit {
        Darwin.close(descriptor)
    }

    var fileURL: URL {
        directory.directoryURL.appendingPathComponent(leafName, isDirectory: false)
    }

    func claimDiscard() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isDiscardClaimed else { return false }
        isDiscardClaimed = true
        return true
    }
}

struct EditorImageAssetPlacementRollbackError: LocalizedError {
    let originalDescription: String
    let cleanupDescriptions: [String]
    let didChangeWorkspace: Bool

    init(
        wrapping error: Error,
        cleanupDescriptions: [String],
        didChangeWorkspace: Bool
    ) {
        if let prior = error as? EditorImageAssetPlacementRollbackError {
            originalDescription = prior.originalDescription
            self.cleanupDescriptions = prior.cleanupDescriptions + cleanupDescriptions
            self.didChangeWorkspace = prior.didChangeWorkspace
                || didChangeWorkspace
                || !self.cleanupDescriptions.isEmpty
        } else {
            originalDescription = error.localizedDescription
            self.cleanupDescriptions = cleanupDescriptions
            self.didChangeWorkspace = didChangeWorkspace || !cleanupDescriptions.isEmpty
        }
    }

    var needsPropagation: Bool {
        didChangeWorkspace || !cleanupDescriptions.isEmpty
    }

    var errorDescription: String? {
        guard !cleanupDescriptions.isEmpty else { return originalDescription }
        return "\(originalDescription) Cleanup also needs attention: " +
            cleanupDescriptions.joined(separator: "; ")
    }
}

func placeEditorImageAssets(
    assets: [EditorImageAsset],
    assetFolderRelativePath: String,
    rootURL: URL,
    currentFileURL: URL,
    rootAuthority capturedRootAuthority: WorkspaceFileSystemRootAuthority? = nil,
    eventHandler: EditorImageAssetPlacementEventHandler? = nil
) throws -> EditorImageAssetPlacement {
    let securityScopedURL = capturedRootAuthority?.securityScopedURL ?? rootURL
    return try SecurityScopedAccess.withAccess(to: securityScopedURL) {
        let rootAuthority = try capturedRootAuthority ?? WorkspaceFileSystemRootAuthority(
            rootURL: rootURL,
            securityScopedURL: securityScopedURL
        )
        try rootAuthority.proveSelectedSpellingNamesCapturedIdentity(
            selectedRootURL: rootURL
        )
        let currentLocation = try rootAuthority.canonicalizedLocation(
            forFileURL: currentFileURL
        )
        let documentAuthority = try EditorImageAssetDocumentAuthority(
            location: currentLocation
        )
        return try placeEditorImageAssets(
            assets: assets,
            assetFolderRelativePath: assetFolderRelativePath,
            documentAuthority: documentAuthority,
            eventHandler: eventHandler,
            managesSecurityScope: false
        )
    }
}

func placeEditorImageAssets(
    assets: [EditorImageAsset],
    assetFolderRelativePath: String,
    documentAuthority: EditorImageAssetDocumentAuthority,
    eventHandler: EditorImageAssetPlacementEventHandler? = nil
) throws -> EditorImageAssetPlacement {
    try placeEditorImageAssets(
        assets: assets,
        assetFolderRelativePath: assetFolderRelativePath,
        documentAuthority: documentAuthority,
        eventHandler: eventHandler,
        managesSecurityScope: true
    )
}

func placeEditorImageAssets(
    assets: [EditorImageAsset],
    assetFolderRelativePath: String,
    documentAuthority: EditorImageAssetDocumentAuthority,
    eventHandler: EditorImageAssetPlacementEventHandler?,
    managesSecurityScope: Bool
) throws -> EditorImageAssetPlacement {
    let operation = {
        try documentAuthority.validateNamespaceBinding()
        let context = try EditorImageAssetPlacementContext(
            documentAuthority: documentAuthority,
            assetFolderComponents: editorImageAssetFolderComponents(assetFolderRelativePath),
            eventHandler: eventHandler
        )
        var state = EditorImageAssetPlacementState()

        do {
            for asset in assets {
                try documentAuthority.validateNamespaceBinding()
                try appendEditorImageAsset(asset, context: context, state: &state)
                try documentAuthority.validateNamespaceBinding()
            }
        } catch {
            let outcome = discardEditorImageAssets(
                state.createdAssets,
                rootURL: documentAuthority.location.securityScopedURL
            )
            let rollbackError = EditorImageAssetPlacementRollbackError(
                wrapping: error,
                cleanupDescriptions: outcome.issues,
                didChangeWorkspace: outcome.didChangeWorkspace
            )
            if rollbackError.needsPropagation { throw rollbackError }
            throw error
        }

        return EditorImageAssetPlacement(
            relativePaths: state.relativePaths,
            createdAssets: state.createdAssets,
            documentAuthority: documentAuthority,
            retainedReferences: state.retainedReferences
        )
    }

    if managesSecurityScope {
        return try SecurityScopedAccess.withAccess(
            to: documentAuthority.location.securityScopedURL,
            operation
        )
    }
    return try operation()
}

private struct EditorImageAssetPlacementContext {
    let documentAuthority: EditorImageAssetDocumentAuthority
    let assetFolderComponents: [String]
    let eventHandler: EditorImageAssetPlacementEventHandler?

    var rootAuthority: WorkspaceFileSystemRootAuthority {
        documentAuthority.rootAuthority
    }

    var currentDirectoryComponents: [String] {
        documentAuthority.currentDirectoryComponents
    }
}

private struct EditorImageAssetPlacementState {
    var relativePaths: [String] = []
    var createdAssets: [CreatedEditorImageAsset] = []
    var retainedReferences: [RetainedEditorImageAssetReference] = []
    var assetDirectory: EditorImageAssetDirectoryLease?
}

private func appendEditorImageAsset(
    _ asset: EditorImageAsset,
    context: EditorImageAssetPlacementContext,
    state: inout EditorImageAssetPlacementState
) throws {
    switch asset {
    case let .data(data, suggestedFilename):
        try validateEditorImageData(data, suggestedFilename: suggestedFilename)
        try appendCreatedEditorImageAsset(
            data,
            filename: sanitizedEditorImageFilename(suggestedFilename),
            context: context,
            state: &state
        )
    case let .file(sourceURL):
        try appendEditorImageFile(sourceURL, context: context, state: &state)
    }
}

private func appendEditorImageFile(
    _ sourceURL: URL,
    context: EditorImageAssetPlacementContext,
    state: inout EditorImageAssetPlacementState
) throws {
    try SecurityScopedAccess.withAccess(to: sourceURL) {
        // Keep the supplied literal spelling. `resolvingSymlinksInPath()` can rewrite the
        // descriptor-canonical `/private/var/...` spelling back through the `/var` symlink;
        // that both loses workspace containment and makes the no-follow import open fail.
        if let sourceLocation = try? context.rootAuthority.canonicalizedLocation(
            forFileURL: sourceURL
        ) {
            let sourceAuthority = try EditorImageAssetDocumentAuthority(
                location: sourceLocation
            )
            try context.eventHandler?(
                .didCaptureWorkspaceReference(sourceLocation.fileURL)
            )
            let retainedProof = try validatedRetainedEditorImageAssetProof(
                authority: sourceAuthority
            )
            try context.documentAuthority.validateNamespaceBinding()
            try sourceAuthority.validateNamespaceBinding()
            state.retainedReferences.append(RetainedEditorImageAssetReference(
                authority: sourceAuthority,
                proof: retainedProof
            ))
            state.relativePaths.append(editorImageRelativePath(
                from: context.currentDirectoryComponents,
                to: sourceLocation.relativePath
                    .split(separator: "/", omittingEmptySubsequences: true)
                    .map(String.init)
            ))
            return
        }

        let importedData = try withValidatedEditorImageFile(at: sourceURL) {
            try readEditorImageFile(from: $0)
        }
        try appendCreatedEditorImageAsset(
            importedData,
            filename: sanitizedEditorImageFilename(sourceURL.lastPathComponent),
            context: context,
            state: &state
        )
    }
}

private func validatedRetainedEditorImageAssetProof(
    authority: EditorImageAssetDocumentAuthority
) throws -> EditorImageAssetContentProof {
    let fileURL = authority.location.fileURL
    guard fileURL.isFileURL,
          !fileURL.path(percentEncoded: false).utf8.contains(0)
    else {
        throw WorkspaceImageAssetStoreError.unsupportedImageType(fileURL.lastPathComponent)
    }
    try validateEditorImageFilename(fileURL.lastPathComponent)

    // The authority retains both the leaf and every parent descriptor. Validate that chain
    // before and after reading so no path lookup can substitute the bytes being authorized.
    try authority.validateNamespaceBinding()
    let metadata = try editorImageAssetStableMetadata(descriptor: authority.descriptor)
    guard metadata.byteCount <= MarkdownImageAssetPolicy.maximumFileSizeBytes else {
        throw WorkspaceImageAssetStoreError.importedImageTooLarge(
            fileURL.lastPathComponent,
            maximumBytes: MarkdownImageAssetPolicy.maximumFileSizeBytes
        )
    }
    let proof = try editorImageAssetContentProof(descriptor: authority.descriptor)
    guard proof.identity == authority.identity else {
        throw WorkspaceAnchoredFileSystemError.namespaceChanged
    }
    try authority.validateNamespaceBinding()
    return proof
}

private func appendCreatedEditorImageAsset(
    _ data: Data,
    filename: String,
    context: EditorImageAssetPlacementContext,
    state: inout EditorImageAssetPlacementState
) throws {
    let directory = try state.assetDirectory ?? makeEditorImageAssetDirectory(
        documentAuthority: context.documentAuthority,
        assetFolderComponents: context.assetFolderComponents
    )
    state.assetDirectory = directory
    let created = try placeCreatedEditorImageAsset(
        filename: filename,
        directory: directory,
        documentAuthority: context.documentAuthority,
        eventHandler: context.eventHandler
    ) {
        try writeEditorImageData(data, to: $0)
    }
    state.createdAssets.append(created)
    try context.eventHandler?(.didPublish(created.fileURL))
    try context.documentAuthority.validateNamespaceBinding()
    try directory.validateNamespaceBinding()
    state.relativePaths.append(editorImageAssetRelativePath(
        folderComponents: context.assetFolderComponents,
        leafName: created.leafName
    ))
}

func validateEditorImageAssetPlacementForCommit(
    _ placement: EditorImageAssetPlacement
) throws {
    try placement.documentAuthority.validateNamespaceBinding()

    for reference in placement.retainedReferences {
        try reference.authority.validateNamespaceBinding()
        guard try editorImageAssetContentProof(
            descriptor: reference.authority.descriptor
        ) == reference.proof else {
            throw WorkspaceAnchoredFileSystemError.changedContent
        }
    }

    for asset in placement.createdAssets {
        try asset.directory.validateNamespaceBinding()
        try validateEditorImageNamespaceEntry(
            directoryDescriptor: asset.directory.descriptor,
            leafName: asset.leafName,
            expectedIdentity: asset.proof.identity
        )
        guard try editorImageAssetContentProof(descriptor: asset.descriptor) == asset.proof else {
            throw WorkspaceAnchoredFileSystemError.changedContent
        }
    }

    // Hashing one receipt can give another namespace time to move. Finish with a complete
    // namespace-only pass immediately before EditorKit performs the synchronous Markdown edit.
    try placement.documentAuthority.validateNamespaceBinding()
    for reference in placement.retainedReferences {
        try reference.authority.validateNamespaceBinding()
    }
    for asset in placement.createdAssets {
        try asset.directory.validateNamespaceBinding()
        try validateEditorImageNamespaceEntry(
            directoryDescriptor: asset.directory.descriptor,
            leafName: asset.leafName,
            expectedIdentity: asset.proof.identity
        )
    }
}

private func makeEditorImageAssetDirectory(
    documentAuthority: EditorImageAssetDocumentAuthority,
    assetFolderComponents: [String]
) throws -> EditorImageAssetDirectoryLease {
    try documentAuthority.validateNamespaceBinding()
    let currentDirectoryComponents = documentAuthority.currentDirectoryComponents
    return try makeEditorImageDirectoryLease(
        rootAuthority: documentAuthority.rootAuthority,
        directoryComponents: currentDirectoryComponents + assetFolderComponents,
        createMissingFromIndex: currentDirectoryComponents.count
    )
}

private func placeCreatedEditorImageAsset(
    filename: String,
    directory: EditorImageAssetDirectoryLease,
    documentAuthority: EditorImageAssetDocumentAuthority,
    eventHandler: EditorImageAssetPlacementEventHandler?,
    writeContents: (Int32) throws -> Void
) throws -> CreatedEditorImageAsset {
    try documentAuthority.validateNamespaceBinding()
    try directory.validateNamespaceBinding()
    let stagingName = ".plainsong-image-stage-\(UUID().uuidString)"
    let stagingDescriptor = stagingName.withCString {
        Darwin.openat(
            directory.descriptor,
            $0,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
    }
    guard stagingDescriptor >= 0 else { throw editorImagePOSIXError() }
    var stagingProof: EditorImageAssetContentProof?
    var publishedAsset: CreatedEditorImageAsset?
    do {
        try writeContents(stagingDescriptor)
        guard Darwin.fchmod(
            stagingDescriptor,
            mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        ) == 0 else {
            throw editorImagePOSIXError()
        }
        guard Darwin.fsync(stagingDescriptor) == 0 else { throw editorImagePOSIXError() }
        let proof = try editorImageAssetContentProof(descriptor: stagingDescriptor)
        stagingProof = proof
        try validateEditorImageNamespaceEntry(
            directoryDescriptor: directory.descriptor,
            leafName: stagingName,
            expectedIdentity: proof.identity
        )

        return try publishStagedEditorImageAsset(
            filename: filename,
            stagingName: stagingName,
            stagingDescriptor: stagingDescriptor,
            proof: proof,
            directory: directory,
            documentAuthority: documentAuthority,
            eventHandler: eventHandler,
            publishedAsset: &publishedAsset
        )
    } catch {
        let proof = stagingProof ?? (try? editorImageAssetContentProof(descriptor: stagingDescriptor))
        let cleanupDisposition: EditorImageAssetDiscardDisposition = if let publishedAsset {
            discardCreatedEditorImageAsset(publishedAsset, eventHandler: nil)
        } else if let proof {
            discardCreatedEditorImageAsset(CreatedEditorImageAsset(
                directory: directory,
                descriptor: stagingDescriptor,
                leafName: stagingName,
                proof: proof
            ), eventHandler: nil)
        } else {
            .preservedOriginal(
                editorImageAssetPreservedLocation(
                    descriptor: stagingDescriptor,
                    leafNameHint: stagingName
                ),
                reason: "could not establish stable staging content proof"
            )
        }
        if publishedAsset == nil, proof == nil {
            Darwin.close(stagingDescriptor)
        }
        let rollbackError = EditorImageAssetPlacementRollbackError(
            wrapping: error,
            cleanupDescriptions: editorImageAssetCleanupDescription(cleanupDisposition).map {
                [$0]
            } ?? [],
            didChangeWorkspace: editorImageAssetDiscardDidChangeWorkspace(cleanupDisposition)
        )
        if rollbackError.needsPropagation { throw rollbackError }
        throw error
    }
}

private func publishStagedEditorImageAsset(
    filename: String,
    stagingName: String,
    stagingDescriptor: Int32,
    proof: EditorImageAssetContentProof,
    directory: EditorImageAssetDirectoryLease,
    documentAuthority: EditorImageAssetDocumentAuthority,
    eventHandler: EditorImageAssetPlacementEventHandler?,
    publishedAsset: inout CreatedEditorImageAsset?
) throws -> CreatedEditorImageAsset {
    for index in 0 ..< Int.max {
        let candidate = uniqueEditorImageFilename(filename, index: index)
        let candidateURL = directory.directoryURL.appendingPathComponent(
            candidate,
            isDirectory: false
        )
        try eventHandler?(.willPublish(candidateURL))
        try validateEditorImageNamespaceEntry(
            directoryDescriptor: directory.descriptor,
            leafName: stagingName,
            expectedIdentity: proof.identity
        )
        guard try editorImageAssetContentProof(descriptor: stagingDescriptor) == proof else {
            throw CocoaError(.fileReadUnknown)
        }
        try documentAuthority.validateNamespaceBinding()
        try directory.validateNamespaceBinding()
        let renameResult = secureEditorImageRename(
            parentDescriptor: directory.descriptor,
            from: stagingName,
            to: candidate,
            flags: UInt32(RENAME_EXCL)
        )
        if renameResult == 0 {
            let created = CreatedEditorImageAsset(
                directory: directory,
                descriptor: stagingDescriptor,
                leafName: candidate,
                proof: proof
            )
            publishedAsset = created
            try eventHandler?(.didRenameBeforeValidation(candidateURL))
            try documentAuthority.validateNamespaceBinding()
            try directory.validateNamespaceBinding()
            try validateEditorImageNamespaceEntry(
                directoryDescriptor: directory.descriptor,
                leafName: candidate,
                expectedIdentity: proof.identity
            )
            guard try editorImageAssetContentProof(descriptor: stagingDescriptor) == proof else {
                throw CocoaError(.fileReadUnknown)
            }
            return created
        }
        guard errno == EEXIST else { throw editorImagePOSIXError() }
    }
    throw WorkspaceImageAssetStoreError.couldNotCreateAssetFile(filename)
}

private func editorImageAssetDiscardPreflightDisposition(
    _ asset: CreatedEditorImageAsset,
    descriptorLinkInspector: EditorImageAssetDescriptorLinkInspector
) -> EditorImageAssetDiscardDisposition? {
    var publishedStatus = stat()
    let publishedStatusResult = asset.leafName.withCString {
        Darwin.fstatat(
            asset.directory.descriptor,
            $0,
            &publishedStatus,
            AT_SYMLINK_NOFOLLOW
        )
    }
    guard publishedStatusResult == 0 else {
        let failure = errno
        if failure == ENOENT {
            return preservedLinkedCreatedEditorImageAssetDisposition(
                asset,
                reason: "published name is missing, but the created asset remains linked elsewhere",
                descriptorLinkInspector: descriptorLinkInspector
            ) ?? .missing
        }
        return .preservedOriginal(
            editorImageAssetPreservedLocation(
                descriptor: asset.descriptor,
                leafNameHint: asset.leafName
            ),
            reason: editorImageErrorDescription(failure)
        )
    }
    let publishedIdentity = WorkspaceFileSystemIdentity(
        device: UInt64(publishedStatus.st_dev),
        inode: UInt64(publishedStatus.st_ino)
    )
    guard (publishedStatus.st_mode & S_IFMT) == S_IFREG,
          publishedIdentity == asset.proof.identity
    else {
        var artifacts = [EditorImageAssetPreservedArtifact(
            location: editorImageAssetPreservedLocationForNamespaceEntry(
                directoryDescriptor: asset.directory.descriptor,
                leafName: asset.leafName,
                fallbackIdentity: publishedIdentity
            ),
            reason: "namespace entry no longer names the created asset",
            isRecovery: false
        )]
        if let createdArtifact = preservedLinkedCreatedEditorImageAssetArtifact(
            asset,
            reason: "created asset remains linked outside its published name",
            isRecovery: false,
            descriptorLinkInspector: descriptorLinkInspector
        ) {
            artifacts.append(createdArtifact)
        }
        return .preservedArtifacts(artifacts, didChangeWorkspace: false)
    }
    return nil
}

func discardCreatedEditorImageAsset(
    _ asset: CreatedEditorImageAsset,
    directorySynchronizer: EditorImageAssetDirectorySynchronizer =
        synchronizeEditorImageAssetDirectory,
    namespaceInspector: EditorImageAssetNamespaceInspector =
        inspectEditorImageAssetNamespaceEntry,
    descriptorLinkInspector: EditorImageAssetDescriptorLinkInspector =
        inspectEditorImageAssetDescriptorLinks,
    eventHandler: EditorImageAssetDiscardEventHandler?
) -> EditorImageAssetDiscardDisposition {
    if let disposition = editorImageAssetDiscardPreflightDisposition(
        asset,
        descriptorLinkInspector: descriptorLinkInspector
    ) {
        return disposition
    }

    // Darwin does not expose an atomic compare-identity-and-unlink operation. Acquire the
    // namespace entry with an exclusive descriptor-relative rename, then retain the acquired
    // vnode under a visible recovery name. Never name-delete from a prior identity check: a
    // watcher could replace that entry between validation and unlink.
    let preservationName = editorImageAssetPreservationName(for: asset.leafName)
    do {
        try eventHandler?(.willRename(originalLeafName: asset.leafName))
    } catch {
        return .preservedOriginal(
            editorImageAssetPreservedLocation(
                descriptor: asset.descriptor,
                leafNameHint: asset.leafName
            ),
            reason: error.localizedDescription
        )
    }
    let renameResult = secureEditorImageRename(
        parentDescriptor: asset.directory.descriptor,
        from: asset.leafName,
        to: preservationName,
        flags: UInt32(RENAME_EXCL)
    )
    guard renameResult == 0 else {
        let failure = errno
        if failure == ENOENT {
            return preservedLinkedCreatedEditorImageAssetDisposition(
                asset,
                reason: "published name disappeared before cleanup, but the created asset " +
                    "remains linked elsewhere",
                descriptorLinkInspector: descriptorLinkInspector
            ) ?? .missing
        }
        if let currentDisposition = editorImageAssetDiscardPreflightDisposition(
            asset,
            descriptorLinkInspector: descriptorLinkInspector
        ) {
            return currentDisposition
        }
        return .preservedOriginal(
            editorImageAssetPreservedLocation(
                descriptor: asset.descriptor,
                leafNameHint: asset.leafName
            ),
            reason: editorImageErrorDescription(failure)
        )
    }

    let disposition = preserveRenamedEditorImageAsset(
        asset,
        preservationName: preservationName,
        directorySynchronizer: directorySynchronizer,
        namespaceInspector: namespaceInspector,
        descriptorLinkInspector: descriptorLinkInspector,
        eventHandler: eventHandler
    )
    return addingUnknownAcquiredEditorImageAssetRecovery(
        to: disposition,
        preservationName: preservationName
    )
}

private func preserveRenamedEditorImageAsset(
    _ asset: CreatedEditorImageAsset,
    preservationName: String,
    directorySynchronizer: EditorImageAssetDirectorySynchronizer,
    namespaceInspector: EditorImageAssetNamespaceInspector,
    descriptorLinkInspector: EditorImageAssetDescriptorLinkInspector,
    eventHandler: EditorImageAssetDiscardEventHandler?
) -> EditorImageAssetDiscardDisposition {
    do {
        try directorySynchronizer(asset.directory.descriptor)
    } catch {
        return preservedUnsynchronizedEditorImageAssetDisposition(
            asset,
            preservationName: preservationName,
            reason: "could not durably record recovery path: \(error.localizedDescription)",
            namespaceInspector: namespaceInspector,
            descriptorLinkInspector: descriptorLinkInspector
        )
    }
    let acquiredSnapshot: EditorImageAssetNamespaceEntrySnapshot
    switch inspectAcquiredEditorImageAssetRecovery(
        asset,
        preservationName: preservationName,
        namespaceInspector: namespaceInspector,
        descriptorLinkInspector: descriptorLinkInspector
    ) {
    case let .snapshot(snapshot):
        acquiredSnapshot = snapshot
    case let .disposition(disposition):
        return disposition
    }
    let acquiredDescriptor = retainEditorImageAssetNamespaceEntry(
        directoryDescriptor: asset.directory.descriptor,
        leafName: preservationName,
        expecting: acquiredSnapshot
    )
    defer {
        if acquiredDescriptor >= 0 { Darwin.close(acquiredDescriptor) }
    }
    do {
        try eventHandler?(.didRename(
            originalLeafName: asset.leafName,
            recoveryLeafName: preservationName
        ))
    } catch {
        return .preservedRecovery(
            preservedEditorImageAssetNamespaceEntryLocation(
                directoryDescriptor: asset.directory.descriptor,
                leafName: preservationName,
                snapshot: acquiredSnapshot,
                retainedDescriptor: acquiredDescriptor
            ),
            reason: error.localizedDescription
        )
    }
    guard acquiredSnapshot.fileType == S_IFREG,
          acquiredSnapshot.identity == asset.proof.identity
    else {
        return preserveRacingEditorImageAssetNamespaceEntry(
            asset,
            preservationName: preservationName,
            acquiredSnapshot: acquiredSnapshot,
            acquiredDescriptor: acquiredDescriptor,
            descriptorLinkInspector: descriptorLinkInspector
        )
    }
    switch validatePreservedEditorImageAsset(
        descriptor: asset.descriptor,
        expectedProof: asset.proof,
        directoryDescriptor: asset.directory.descriptor,
        preservationName: preservationName
    ) {
    case .exact:
        return preserveValidatedEditorImageAsset(
            asset,
            preservationName: preservationName,
            acquiredSnapshot: acquiredSnapshot,
            acquiredDescriptor: acquiredDescriptor,
            eventHandler: eventHandler
        )

    case .changed:
        return .preservedRecovery(
            editorImageAssetPreservedLocation(
                descriptor: asset.descriptor,
                leafNameHint: preservationName
            ),
            reason: "acquired namespace entry did not contain the exact created bytes"
        )

    case let .indeterminate(reason):
        return .preservedRecovery(
            editorImageAssetPreservedLocation(
                descriptor: asset.descriptor,
                leafNameHint: preservationName
            ),
            reason: reason
        )
    }
}

func synchronizeEditorImageAssetDirectory(_ descriptor: Int32) throws {
    guard Darwin.fsync(descriptor) == 0 else { throw editorImagePOSIXError() }
}

private func preserveValidatedEditorImageAsset(
    _ asset: CreatedEditorImageAsset,
    preservationName: String,
    acquiredSnapshot: EditorImageAssetNamespaceEntrySnapshot,
    acquiredDescriptor: Int32,
    eventHandler: EditorImageAssetDiscardEventHandler?
) -> EditorImageAssetDiscardDisposition {
    do {
        try eventHandler?(.didValidateRecovery(recoveryLeafName: preservationName))
    } catch {
        return .preservedRecovery(
            preservedEditorImageAssetNamespaceEntryLocation(
                directoryDescriptor: asset.directory.descriptor,
                leafName: preservationName,
                snapshot: acquiredSnapshot,
                retainedDescriptor: acquiredDescriptor
            ),
            reason: error.localizedDescription
        )
    }
    guard case .exact = validatePreservedEditorImageAsset(
        descriptor: asset.descriptor,
        expectedProof: asset.proof,
        directoryDescriptor: asset.directory.descriptor,
        preservationName: preservationName
    ) else {
        return .preservedRecovery(
            preservedEditorImageAssetNamespaceEntryLocation(
                directoryDescriptor: asset.directory.descriptor,
                leafName: preservationName,
                snapshot: acquiredSnapshot,
                retainedDescriptor: acquiredDescriptor
            ),
            reason: "recovery entry changed after validation; no file was removed"
        )
    }
    return .preservedRecovery(
        preservedEditorImageAssetNamespaceEntryLocation(
            directoryDescriptor: asset.directory.descriptor,
            leafName: preservationName,
            snapshot: acquiredSnapshot,
            retainedDescriptor: acquiredDescriptor
        ),
        reason: "exact created bytes retained because identity-conditional unlink is unavailable"
    )
}

private func preserveRacingEditorImageAssetNamespaceEntry(
    _ asset: CreatedEditorImageAsset,
    preservationName: String,
    acquiredSnapshot: EditorImageAssetNamespaceEntrySnapshot,
    acquiredDescriptor: Int32,
    descriptorLinkInspector: EditorImageAssetDescriptorLinkInspector
) -> EditorImageAssetDiscardDisposition {
    let directoryDescriptor = asset.directory.descriptor
    var artifacts = [
        EditorImageAssetPreservedArtifact(
            location: EditorImageAssetPreservedLocation(
                currentPath: nil,
                identity: nil,
                leafNameHint: preservationName
            ),
            reason: "the entry acquired by the recovery rename has no atomic provenance proof",
            isRecovery: true
        ),
        EditorImageAssetPreservedArtifact(
            location: preservedEditorImageAssetNamespaceEntryLocation(
                directoryDescriptor: directoryDescriptor,
                leafName: preservationName,
                snapshot: acquiredSnapshot,
                retainedDescriptor: acquiredDescriptor
            ),
            reason: "current recovery namespace occupant was observed after the durable rename " +
                "and is not proof of the entry acquired by rename",
            isRecovery: true
        ),
    ]
    if let createdArtifact = preservedLinkedCreatedEditorImageAssetArtifact(
        asset,
        reason: "created asset remains linked outside its published name",
        isRecovery: false,
        descriptorLinkInspector: descriptorLinkInspector
    ) {
        artifacts.append(createdArtifact)
    }
    return .preservedArtifacts(artifacts, didChangeWorkspace: true)
}

private func preservedLinkedCreatedEditorImageAssetDisposition(
    _ asset: CreatedEditorImageAsset,
    reason: String,
    descriptorLinkInspector: EditorImageAssetDescriptorLinkInspector
) -> EditorImageAssetDiscardDisposition? {
    guard let artifact = preservedLinkedCreatedEditorImageAssetArtifact(
        asset,
        reason: reason,
        isRecovery: false,
        descriptorLinkInspector: descriptorLinkInspector
    ) else {
        return nil
    }
    return .preservedArtifacts([artifact], didChangeWorkspace: false)
}

func preservedLinkedCreatedEditorImageAssetArtifact(
    _ asset: CreatedEditorImageAsset,
    reason: String,
    isRecovery: Bool,
    descriptorLinkInspector: EditorImageAssetDescriptorLinkInspector
) -> EditorImageAssetPreservedArtifact? {
    let location: EditorImageAssetPreservedLocation
    let artifactReason: String
    switch descriptorLinkInspector(asset.descriptor) {
    case .linked:
        location = editorImageAssetPreservedLocation(
            descriptor: asset.descriptor,
            leafNameHint: asset.leafName
        )
        artifactReason = reason

    case .unlinked:
        return nil

    case let .indeterminate(inspectionReason):
        location = EditorImageAssetPreservedLocation(
            currentPath: nil,
            identity: asset.proof.identity,
            leafNameHint: asset.leafName
        )
        artifactReason = "cleanup could not prove the created asset was unlinked: " +
            inspectionReason
    }
    return EditorImageAssetPreservedArtifact(
        location: location,
        reason: artifactReason,
        isRecovery: isRecovery
    )
}

private func retainEditorImageAssetNamespaceEntry(
    directoryDescriptor: Int32,
    leafName: String,
    expecting snapshot: EditorImageAssetNamespaceEntrySnapshot?
) -> Int32 {
    guard let snapshot else { return -1 }
    let descriptor = leafName.withCString {
        Darwin.openat(
            directoryDescriptor,
            $0,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
    }
    guard descriptor >= 0 else { return -1 }
    guard editorImageAssetNamespaceEntrySnapshot(descriptor: descriptor) == snapshot else {
        Darwin.close(descriptor)
        return -1
    }
    return descriptor
}

private func preservedEditorImageAssetNamespaceEntryLocation(
    directoryDescriptor: Int32,
    leafName: String,
    snapshot: EditorImageAssetNamespaceEntrySnapshot?,
    retainedDescriptor: Int32
) -> EditorImageAssetPreservedLocation {
    if retainedDescriptor >= 0 {
        let retained = editorImageAssetPreservedLocation(
            descriptor: retainedDescriptor,
            leafNameHint: leafName
        )
        if retained.identity == snapshot?.identity,
           retained.currentPath != nil
        {
            return retained
        }
    }
    return editorImageAssetPreservedLocationForNamespaceEntry(
        directoryDescriptor: directoryDescriptor,
        leafName: leafName,
        fallbackIdentity: snapshot?.identity
    )
}
