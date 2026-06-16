import EditorKit
import Foundation
import WorkspaceKit

@MainActor
extension AppState {
    var editorImageAssetInserter: EditorImageAssetInserter? {
        guard workspaceRootURL != nil, currentDocument.fileURL != nil else {
            return nil
        }

        return { [weak self] assets in
            await self?.insertEditorImageAssets(assets) ?? []
        }
    }

    private func insertEditorImageAssets(_ assets: [EditorImageAsset]) async -> [String] {
        guard let rootURL = workspaceRootURL,
              let currentFileURL = currentDocument.fileURL
        else {
            return []
        }

        let workspaceSources = assets.map { asset in
            switch asset {
            case let .data(data, suggestedFilename):
                WorkspaceImageAssetSource.data(data, suggestedFilename: suggestedFilename)
            case let .file(url):
                WorkspaceImageAssetSource.file(url)
            }
        }

        do {
            let paths = try await Task.detached(priority: .userInitiated) {
                try WorkspaceImageAssetStore().place(
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
