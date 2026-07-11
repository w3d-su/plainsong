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

        return { [weak self, rootURL, currentFileURL] assets in
            await self?.insertEditorImageAssets(
                assets,
                rootURL: rootURL,
                currentFileURL: currentFileURL
            ) ?? []
        }
    }

    private func insertEditorImageAssets(
        _ assets: [EditorImageAsset],
        rootURL: URL,
        currentFileURL: URL
    ) async -> [String] {
        let workspaceSources = assets.map { asset in
            switch asset {
            case let .data(data, suggestedFilename):
                WorkspaceImageAssetSource.data(data, suggestedFilename: suggestedFilename)
            case let .file(url):
                WorkspaceImageAssetSource.file(url)
            }
        }
        let assetFolderRelativePath = preferences.assetFolderRelativePath

        do {
            let paths = try await Task.detached(priority: .userInitiated) {
                try WorkspaceImageAssetStore(
                    assetFolderRelativePath: assetFolderRelativePath
                ).place(
                    workspaceSources,
                    rootURL: rootURL,
                    currentFileURL: currentFileURL
                )
            }.value

            refreshWorkspaceAfterFileSystemChange()
            return paths
        } catch {
            present(error, title: "Could Not Insert Image")
            return []
        }
    }
}

enum WorkspaceImageThumbnailRefreshPaths {
    static func changedRasterPaths(
        from previousSnapshot: WorkspaceFileSnapshot,
        to currentSnapshot: WorkspaceFileSnapshot
    ) -> [String] {
        let previousEntries = entriesByPath(previousSnapshot)
        let currentEntries = entriesByPath(currentSnapshot)
        return Set(previousEntries.keys)
            .union(currentEntries.keys)
            .filter { path in
                guard previousEntries[path] != currentEntries[path],
                      MarkdownImageAssetPolicy.isAllowedPathExtension(
                          (path as NSString).pathExtension
                      )
                else {
                    return false
                }
                return previousEntries[path]?.kind == .image
                    || currentEntries[path]?.kind == .image
            }
            .sorted()
    }

    private static func entriesByPath(
        _ snapshot: WorkspaceFileSnapshot
    ) -> [String: WorkspaceFileSnapshot.Entry] {
        snapshot.entries.reduce(into: [:]) { entries, entry in
            entries[entry.relativePath] = entry
        }
    }
}
