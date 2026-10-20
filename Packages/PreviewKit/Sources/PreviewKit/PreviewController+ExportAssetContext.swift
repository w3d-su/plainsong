import Foundation

/// The asset containment context a render carries (`docs/export-gates.md` D3): the
/// allowed root the `asset://` handler may serve and the workspace-relative base
/// directory relative image URLs resolve against. Moved out of PreviewController.swift
/// to keep it under the file-length budget.
extension PreviewController {
    nonisolated static func assetContext(fileURL: URL?, workspaceRootURL: URL?) -> PreviewAssetContext {
        guard let fileURL = fileURL?.standardizedFileURL else {
            return PreviewAssetContext(allowedRoot: workspaceRootURL?.standardizedFileURL, baseDir: nil)
        }

        guard let workspaceRootURL = workspaceRootURL?.standardizedFileURL,
              fileURL.isDescendant(of: workspaceRootURL)
        else {
            return PreviewAssetContext(
                allowedRoot: fileURL.deletingLastPathComponent().standardizedFileURL,
                baseDir: nil
            )
        }

        return PreviewAssetContext(
            allowedRoot: workspaceRootURL,
            baseDir: fileURL.deletingLastPathComponent().pathRelative(to: workspaceRootURL)
        )
    }
}

struct PreviewAssetContext: Equatable {
    let allowedRoot: URL?
    let baseDir: String?
}

private extension URL {
    func isDescendant(of rootURL: URL) -> Bool {
        let candidatePath = standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let rootPath = Self.normalizedDirectoryPath(
            rootURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        )
        return candidatePath == rootPath || candidatePath.hasPrefix("\(rootPath)/")
    }

    func pathRelative(to rootURL: URL) -> String? {
        let rootPath = Self.normalizedDirectoryPath(rootURL.standardizedFileURL.path(percentEncoded: false))
        let candidatePath = standardizedFileURL.path(percentEncoded: false)
        guard candidatePath == rootPath || candidatePath.hasPrefix("\(rootPath)/") else { return nil }

        var relativePath = String(candidatePath.dropFirst(rootPath.count))
        if relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }
        while relativePath.hasSuffix("/") {
            relativePath.removeLast()
        }
        return relativePath.isEmpty ? nil : relativePath
    }

    static func normalizedDirectoryPath(_ path: String) -> String {
        guard path != "/" else { return path }
        var normalized = path
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
