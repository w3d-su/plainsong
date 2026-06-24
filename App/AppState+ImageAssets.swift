import EditorKit
import Foundation
import WorkspaceKit

@MainActor
extension AppState {
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
