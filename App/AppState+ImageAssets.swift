import CryptoKit
import Darwin
import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

final class WorkspaceEditorImageThumbnailAdapter: EditorImageThumbnailLoading {
    private let provider: any WorkspaceImageThumbnailLoading

    init(provider: any WorkspaceImageThumbnailLoading) {
        self.provider = provider
    }

    func loadThumbnail(
        rootURL: URL,
        documentDirectoryRelativePath: String,
        source: String,
        maxPixelSize: Int
    ) async -> EditorImageThumbnailOutcome {
        let outcome = await provider.loadThumbnail(
            rootURL: rootURL,
            documentDirectoryRelativePath: documentDirectoryRelativePath,
            source: source,
            maxPixelSize: maxPixelSize
        )
        return Self.editorOutcome(from: outcome)
    }

    private static func editorOutcome(
        from outcome: WorkspaceImageThumbnailOutcome
    ) -> EditorImageThumbnailOutcome {
        switch outcome {
        case let .ready(thumbnail):
            .ready(EditorImageThumbnail(
                pngData: thumbnail.pngData,
                pixelWidth: thumbnail.pixelWidth,
                pixelHeight: thumbnail.pixelHeight,
                resolvedWorkspaceRelativePath: thumbnail.resolvedWorkspaceRelativePath,
                contentModificationDate: thumbnail.contentModificationDate
            ))
        case let .stayRaw(reason):
            .stayRaw(reason)
        case let .failed(failure):
            .failed(editorFailure(from: failure))
        }
    }

    private static func editorFailure(
        from failure: WorkspaceImageThumbnailFailure
    ) -> EditorImageThumbnailFailure {
        switch failure {
        case .missingFile:
            .missingFile
        case .unreadableFile:
            .unreadableFile
        case .decodeFailed:
            .decodeFailed
        case .emptyImage:
            .emptyImage
        }
    }
}

@MainActor
extension AppState {
    func editorImageThumbnailConfiguration(
        for session: DocumentSession,
        presentation: MarkdownEditorDevelopmentPresentation
    ) -> EditorImageThumbnailConfiguration? {
        guard presentation == .inlineFoldRevealWithLinkFolding,
              shouldUseWYSIWYGPresentation,
              let rootURL = workspaceRootURL,
              let documentURL = session.fileURL,
              let documentRelativePath = try? WorkspaceRootContainment.relativePath(
                  for: documentURL,
                  rootURL: rootURL
              )
        else {
            return nil
        }

        return EditorImageThumbnailConfiguration(
            loader: editorImageThumbnailAdapter,
            rootURL: rootURL,
            documentDirectoryRelativePath: (documentRelativePath as NSString).deletingLastPathComponent,
            refreshProxy: editorImageThumbnailRefreshProxy
        )
    }

    func refreshEditorImageThumbnails(
        previousSnapshot: WorkspaceFileSnapshot?,
        currentSnapshot: WorkspaceFileSnapshot
    ) {
        guard let previousSnapshot else {
            return
        }
        editorImageThumbnailRefreshProxy.invalidateThumbnails(
            forWorkspaceRelativePaths: WorkspaceImageThumbnailRefreshPaths.changedRasterPaths(
                from: previousSnapshot,
                to: currentSnapshot
            )
        )
    }

    var editorImageAssetInserter: EditorImageAssetInserter? {
        guard let rootURL = workspaceRootURL,
              let currentFileURL = currentDocument.fileURL
        else {
            return nil
        }
        let rootAuthority = workspaceSearchRootAuthority

        return { [weak self, rootURL, currentFileURL, rootAuthority] assets in
            await self?.insertEditorImageAssets(
                assets,
                rootURL: rootURL,
                currentFileURL: currentFileURL,
                rootAuthority: rootAuthority
            ) ?? EditorImageAssetInsertion(relativePaths: [])
        }
    }

    private func insertEditorImageAssets(
        _ assets: [EditorImageAsset],
        rootURL: URL,
        currentFileURL: URL,
        rootAuthority: WorkspaceFileSystemRootAuthority?
    ) async -> EditorImageAssetInsertion {
        let assetFolderRelativePath = preferences.assetFolderRelativePath

        do {
            let placement = try await Task.detached(priority: .userInitiated) {
                try placeEditorImageAssets(
                    assets: assets,
                    assetFolderRelativePath: assetFolderRelativePath,
                    rootURL: rootURL,
                    currentFileURL: currentFileURL,
                    rootAuthority: rootAuthority
                )
            }.value

            refreshWorkspaceAfterFileSystemChange()
            let cleanupSecurityScopedURL = placement.createdAssets.first?
                .directory.rootAuthority.securityScopedURL ?? rootURL
            return EditorImageAssetInsertion(
                relativePaths: placement.relativePaths
            ) { [weak self] in
                let outcome = await Task.detached(priority: .utility) {
                    discardEditorImageAssets(
                        placement.createdAssets,
                        rootURL: cleanupSecurityScopedURL
                    )
                }.value
                if outcome.didChangeWorkspace {
                    self?.refreshWorkspaceAfterFileSystemChange()
                }
                if let issue = outcome.userFacingIssue {
                    self?.present(issue, title: "Image Cleanup Needs Attention")
                }
            }
        } catch {
            present(error, title: "Could Not Insert Image")
            return EditorImageAssetInsertion(relativePaths: [])
        }
    }
}

struct EditorImageAssetPlacement {
    let relativePaths: [String]
    let createdAssets: [CreatedEditorImageAsset]
}

enum EditorImageAssetPlacementEvent: Equatable {
    case willPublish(URL)
    case didPublish(URL)
}

typealias EditorImageAssetPlacementEventHandler = @Sendable (
    EditorImageAssetPlacementEvent
) throws -> Void

struct EditorImageAssetContentProof: Equatable {
    let identity: WorkspaceFileSystemIdentity
    let byteCount: Int64
    let sha256Digest: String
}

private struct EditorImageAssetStableMetadata: Equatable {
    let identity: WorkspaceFileSystemIdentity
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

final class EditorImageAssetDirectoryLease: @unchecked Sendable {
    let descriptor: Int32
    let directoryURL: URL
    let rootAuthority: WorkspaceFileSystemRootAuthority

    init(
        descriptor: Int32,
        directoryURL: URL,
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) {
        self.descriptor = descriptor
        self.directoryURL = directoryURL
        self.rootAuthority = rootAuthority
    }

    deinit {
        Darwin.close(descriptor)
    }
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

private struct EditorImageAssetDiscardOutcome {
    var didChangeWorkspace = false
    var issues: [String] = []

    var userFacingIssue: EditorImageAssetDiscardIssue? {
        issues.isEmpty ? nil : EditorImageAssetDiscardIssue(details: issues)
    }
}

private struct EditorImageAssetDiscardIssue: LocalizedError {
    let details: [String]

    var errorDescription: String? {
        "Plainsong preserved image data because it changed or could not be safely removed: " +
            details.joined(separator: "; ")
    }
}

private struct EditorImageAssetPlacementRollbackError: LocalizedError {
    let originalDescription: String
    let cleanupDescription: String

    var errorDescription: String? {
        "\(originalDescription) Cleanup also needs attention: \(cleanupDescription)"
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
        let context = try EditorImageAssetPlacementContext(
            rootAuthority: rootAuthority,
            currentDirectoryComponents: currentLocation.relativePath
                .split(separator: "/", omittingEmptySubsequences: true)
                .dropLast()
                .map(String.init),
            assetFolderComponents: editorImageAssetFolderComponents(
                assetFolderRelativePath
            ),
            eventHandler: eventHandler
        )
        var state = EditorImageAssetPlacementState()

        do {
            for asset in assets {
                try rootAuthority.proveSelectedSpellingNamesCapturedIdentity(
                    selectedRootURL: rootURL
                )
                try appendEditorImageAsset(asset, context: context, state: &state)
            }
        } catch {
            let outcome = discardEditorImageAssets(
                state.createdAssets,
                rootURL: securityScopedURL
            )
            if let issue = outcome.userFacingIssue {
                throw EditorImageAssetPlacementRollbackError(
                    originalDescription: error.localizedDescription,
                    cleanupDescription: issue.localizedDescription
                )
            }
            throw error
        }

        return EditorImageAssetPlacement(
            relativePaths: state.relativePaths,
            createdAssets: state.createdAssets
        )
    }
}

private struct EditorImageAssetPlacementContext {
    let rootAuthority: WorkspaceFileSystemRootAuthority
    let currentDirectoryComponents: [String]
    let assetFolderComponents: [String]
    let eventHandler: EditorImageAssetPlacementEventHandler?
}

private struct EditorImageAssetPlacementState {
    var relativePaths: [String] = []
    var createdAssets: [CreatedEditorImageAsset] = []
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
        let resolvedSourceURL = sourceURL.resolvingSymlinksInPath()
        if let sourceLocation = try? context.rootAuthority.canonicalizedLocation(
            forFileURL: resolvedSourceURL
        ) {
            try withValidatedEditorImageFile(at: sourceLocation.fileURL) { _ in }
            state.relativePaths.append(editorImageRelativePath(
                from: context.currentDirectoryComponents,
                to: sourceLocation.relativePath
                    .split(separator: "/", omittingEmptySubsequences: true)
                    .map(String.init)
            ))
            return
        }

        let importedData = try withValidatedEditorImageFile(at: resolvedSourceURL) {
            try readEditorImageFile(from: $0)
        }
        try appendCreatedEditorImageAsset(
            importedData,
            filename: sanitizedEditorImageFilename(resolvedSourceURL.lastPathComponent),
            context: context,
            state: &state
        )
    }
}

private func appendCreatedEditorImageAsset(
    _ data: Data,
    filename: String,
    context: EditorImageAssetPlacementContext,
    state: inout EditorImageAssetPlacementState
) throws {
    let directory = try state.assetDirectory ?? makeEditorImageAssetDirectory(
        rootAuthority: context.rootAuthority,
        currentDirectoryComponents: context.currentDirectoryComponents,
        assetFolderComponents: context.assetFolderComponents
    )
    state.assetDirectory = directory
    let created = try placeCreatedEditorImageAsset(
        filename: filename,
        directory: directory,
        eventHandler: context.eventHandler
    ) {
        try writeEditorImageData(data, to: $0)
    }
    state.createdAssets.append(created)
    try context.eventHandler?(.didPublish(created.fileURL))
    state.relativePaths.append(editorImageAssetRelativePath(
        folderComponents: context.assetFolderComponents,
        leafName: created.leafName
    ))
}

private func makeEditorImageAssetDirectory(
    rootAuthority: WorkspaceFileSystemRootAuthority,
    currentDirectoryComponents: [String],
    assetFolderComponents: [String]
) throws -> EditorImageAssetDirectoryLease {
    let rootURL = rootAuthority.canonicalRootURL
    var descriptor = Darwin.open(
        rootURL.path(percentEncoded: false),
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
    )
    guard descriptor >= 0 else { throw editorImagePOSIXError() }
    var directoryURL = rootURL

    do {
        let verification = try WorkspaceFileSystemRootAuthority(
            rootURL: rootURL,
            securityScopedURL: rootAuthority.securityScopedURL
        )
        guard verification == rootAuthority else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        for component in currentDirectoryComponents {
            let nextDescriptor = try openEditorImageDirectory(
                parentDescriptor: descriptor,
                component: component,
                createIfMissing: false
            )
            Darwin.close(descriptor)
            descriptor = nextDescriptor
            directoryURL.appendPathComponent(component, isDirectory: true)
        }
        for component in assetFolderComponents {
            let nextDescriptor = try openEditorImageDirectory(
                parentDescriptor: descriptor,
                component: component,
                createIfMissing: true
            )
            Darwin.close(descriptor)
            descriptor = nextDescriptor
            directoryURL.appendPathComponent(component, isDirectory: true)
        }
        return EditorImageAssetDirectoryLease(
            descriptor: descriptor,
            directoryURL: directoryURL,
            rootAuthority: rootAuthority
        )
    } catch {
        Darwin.close(descriptor)
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

private func placeCreatedEditorImageAsset(
    filename: String,
    directory: EditorImageAssetDirectoryLease,
    eventHandler: EditorImageAssetPlacementEventHandler?,
    writeContents: (Int32) throws -> Void
) throws -> CreatedEditorImageAsset {
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
            eventHandler: eventHandler,
            publishedAsset: &publishedAsset
        )
    } catch {
        let proof = stagingProof ?? (try? editorImageAssetContentProof(descriptor: stagingDescriptor))
        let cleanupDisposition: EditorImageAssetDiscardDisposition = if let publishedAsset {
            discardCreatedEditorImageAsset(publishedAsset)
        } else if let proof {
            discardCreatedEditorImageAsset(CreatedEditorImageAsset(
                directory: directory,
                descriptor: stagingDescriptor,
                leafName: stagingName,
                proof: proof
            ))
        } else {
            .preservedOriginal(
                directory.directoryURL.appendingPathComponent(stagingName),
                reason: "could not establish stable staging content proof"
            )
        }
        if publishedAsset == nil, proof == nil {
            Darwin.close(stagingDescriptor)
        }
        if let cleanupDescription = editorImageAssetCleanupDescription(cleanupDisposition) {
            throw EditorImageAssetPlacementRollbackError(
                originalDescription: error.localizedDescription,
                cleanupDescription: cleanupDescription
            )
        }
        throw error
    }
}

private func publishStagedEditorImageAsset(
    filename: String,
    stagingName: String,
    stagingDescriptor: Int32,
    proof: EditorImageAssetContentProof,
    directory: EditorImageAssetDirectoryLease,
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

private func discardEditorImageAssets(
    _ assets: [CreatedEditorImageAsset],
    rootURL: URL
) -> EditorImageAssetDiscardOutcome {
    SecurityScopedAccess.withAccess(to: rootURL) {
        var outcome = EditorImageAssetDiscardOutcome()
        for asset in assets {
            guard asset.claimDiscard() else { continue }
            switch discardCreatedEditorImageAsset(asset) {
            case .removed:
                outcome.didChangeWorkspace = true
            case .missing:
                continue
            case let .restoredChanged(fileURL):
                outcome.didChangeWorkspace = true
                outcome.issues.append("changed asset preserved at \(fileURL.path(percentEncoded: false))")
            case let .preservedOriginal(fileURL, reason):
                outcome.issues.append(
                    "asset preserved at \(fileURL.path(percentEncoded: false)) (\(reason))"
                )
            case let .preservedQuarantine(fileURL, reason):
                outcome.didChangeWorkspace = true
                outcome.issues.append(
                    "asset preserved in quarantine at \(fileURL.path(percentEncoded: false)) (\(reason))"
                )
            }
        }
        return outcome
    }
}

private enum EditorImageAssetDiscardDisposition {
    case removed
    case missing
    case restoredChanged(URL)
    case preservedOriginal(URL, reason: String)
    case preservedQuarantine(URL, reason: String)
}

private func editorImageAssetCleanupDescription(
    _ disposition: EditorImageAssetDiscardDisposition
) -> String? {
    switch disposition {
    case .removed, .missing:
        nil
    case let .restoredChanged(fileURL):
        "changed staging file preserved at \(fileURL.path(percentEncoded: false))"
    case let .preservedOriginal(fileURL, reason):
        "staging file preserved at \(fileURL.path(percentEncoded: false)) (\(reason))"
    case let .preservedQuarantine(fileURL, reason):
        "staging file preserved in quarantine at \(fileURL.path(percentEncoded: false)) (\(reason))"
    }
}

private enum EditorImageAssetQuarantineValidation {
    case exact
    case changed
    case indeterminate(String)
}

private func discardCreatedEditorImageAsset(
    _ asset: CreatedEditorImageAsset
) -> EditorImageAssetDiscardDisposition {
    let quarantineName = ".plainsong-image-rollback-\(UUID().uuidString)"
    let renameResult = secureEditorImageRename(
        parentDescriptor: asset.directory.descriptor,
        from: asset.leafName,
        to: quarantineName,
        flags: UInt32(RENAME_EXCL)
    )
    guard renameResult == 0 else {
        let failure = errno
        if failure == ENOENT { return .missing }
        return .preservedOriginal(asset.fileURL, reason: editorImageErrorDescription(failure))
    }

    let quarantineURL = asset.directory.directoryURL.appendingPathComponent(
        quarantineName,
        isDirectory: false
    )
    switch validateQuarantinedEditorImageAsset(asset, quarantineName: quarantineName) {
    case .exact:
        guard (try? validateEditorImageNamespaceEntry(
            directoryDescriptor: asset.directory.descriptor,
            leafName: quarantineName,
            expectedIdentity: asset.proof.identity
        )) != nil
        else {
            return restoreQuarantinedEditorImageAsset(
                asset,
                quarantineName: quarantineName,
                quarantineURL: quarantineURL,
                reason: "quarantine identity changed before removal"
            )
        }
        let unlinkResult = quarantineName.withCString {
            Darwin.unlinkat(asset.directory.descriptor, $0, 0)
        }
        guard unlinkResult == 0 else {
            return .preservedQuarantine(
                quarantineURL,
                reason: editorImageErrorDescription(errno)
            )
        }
        return .removed

    case .changed:
        return restoreQuarantinedEditorImageAsset(
            asset,
            quarantineName: quarantineName,
            quarantineURL: quarantineURL,
            reason: "identity or bytes changed"
        )

    case let .indeterminate(reason):
        return restoreQuarantinedEditorImageAsset(
            asset,
            quarantineName: quarantineName,
            quarantineURL: quarantineURL,
            reason: reason
        )
    }
}

private func validateQuarantinedEditorImageAsset(
    _ asset: CreatedEditorImageAsset,
    quarantineName: String
) -> EditorImageAssetQuarantineValidation {
    do {
        let before = try editorImageAssetStableMetadata(descriptor: asset.descriptor)
        guard before.identity == asset.proof.identity,
              before.byteCount == asset.proof.byteCount
        else {
            return .changed
        }
        let digest = try editorImageSHA256Digest(descriptor: asset.descriptor)
        let after = try editorImageAssetStableMetadata(descriptor: asset.descriptor)
        guard before == after else { return .indeterminate("asset changed while validating") }
        try validateEditorImageNamespaceEntry(
            directoryDescriptor: asset.directory.descriptor,
            leafName: quarantineName,
            expectedIdentity: after.identity
        )
        return digest == asset.proof.sha256Digest ? .exact : .changed
    } catch {
        return .indeterminate(error.localizedDescription)
    }
}

private func restoreQuarantinedEditorImageAsset(
    _ asset: CreatedEditorImageAsset,
    quarantineName: String,
    quarantineURL: URL,
    reason: String
) -> EditorImageAssetDiscardDisposition {
    let restoreResult = secureEditorImageRename(
        parentDescriptor: asset.directory.descriptor,
        from: quarantineName,
        to: asset.leafName,
        flags: UInt32(RENAME_EXCL)
    )
    if restoreResult == 0 {
        return .restoredChanged(asset.fileURL)
    }
    return .preservedQuarantine(
        quarantineURL,
        reason: "\(reason); restore failed: \(editorImageErrorDescription(errno))"
    )
}

private func editorImageAssetContentProof(descriptor: Int32) throws -> EditorImageAssetContentProof {
    let before = try editorImageAssetStableMetadata(descriptor: descriptor)
    let digest = try editorImageSHA256Digest(descriptor: descriptor)
    let after = try editorImageAssetStableMetadata(descriptor: descriptor)
    guard before == after else { throw CocoaError(.fileReadUnknown) }
    return EditorImageAssetContentProof(
        identity: after.identity,
        byteCount: after.byteCount,
        sha256Digest: digest
    )
}

private func editorImageAssetStableMetadata(
    descriptor: Int32
) throws -> EditorImageAssetStableMetadata {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG
    else {
        throw editorImagePOSIXError()
    }
    return EditorImageAssetStableMetadata(
        identity: WorkspaceFileSystemIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        ),
        byteCount: Int64(status.st_size),
        modificationSeconds: Int64(status.st_mtimespec.tv_sec),
        modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
        changeSeconds: Int64(status.st_ctimespec.tv_sec),
        changeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
    )
}

private func validateEditorImageNamespaceEntry(
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
        throw CocoaError(.fileReadUnknown)
    }
}

private func editorImageSHA256Digest(descriptor: Int32) throws -> String {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { throw editorImagePOSIXError() }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw editorImagePOSIXError() }
        guard count > 0 else { break }
        hasher.update(data: Data(buffer.prefix(count)))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func writeEditorImageData(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(
                descriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw editorImagePOSIXError() }
            offset += count
        }
    }
}

private func readEditorImageFile(from descriptor: Int32) throws -> Data {
    let before = try editorImageAssetStableMetadata(descriptor: descriptor)
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { throw editorImagePOSIXError() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw editorImagePOSIXError() }
        guard count > 0 else { break }
        guard Int64(data.count) + Int64(count) <= MarkdownImageAssetPolicy.maximumFileSizeBytes else {
            throw WorkspaceImageAssetStoreError.importedImageTooLarge(
                "image",
                maximumBytes: MarkdownImageAssetPolicy.maximumFileSizeBytes
            )
        }
        data.append(contentsOf: buffer.prefix(count))
    }
    let after = try editorImageAssetStableMetadata(descriptor: descriptor)
    guard before == after,
          after.byteCount == Int64(data.count)
    else {
        throw CocoaError(.fileReadUnknown)
    }
    return data
}

private func withValidatedEditorImageFile<Result>(
    at fileURL: URL,
    _ body: (Int32) throws -> Result
) throws -> Result {
    guard fileURL.isFileURL,
          !fileURL.path(percentEncoded: false).utf8.contains(0)
    else {
        throw WorkspaceImageAssetStoreError.unsupportedImageType(fileURL.lastPathComponent)
    }
    try validateEditorImageFilename(fileURL.lastPathComponent)
    let descriptor = Darwin.open(
        fileURL.path(percentEncoded: false),
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK
    )
    guard descriptor >= 0 else { throw editorImagePOSIXError() }
    defer { Darwin.close(descriptor) }
    let metadata = try editorImageAssetStableMetadata(descriptor: descriptor)
    guard metadata.byteCount <= MarkdownImageAssetPolicy.maximumFileSizeBytes else {
        throw WorkspaceImageAssetStoreError.importedImageTooLarge(
            fileURL.lastPathComponent,
            maximumBytes: MarkdownImageAssetPolicy.maximumFileSizeBytes
        )
    }
    let resourceValues = try fileURL.resourceValues(forKeys: [.contentTypeKey])
    if let contentType = resourceValues.contentType,
       !allowedEditorImageTypes.contains(where: { contentType.conforms(to: $0) })
    {
        throw WorkspaceImageAssetStoreError.unsupportedImageType(fileURL.lastPathComponent)
    }
    return try body(descriptor)
}
