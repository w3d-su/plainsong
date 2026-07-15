import Darwin
import Foundation
import MarkdownCore
import UniformTypeIdentifiers
import WorkspaceKit

func validateEditorImageData(_ data: Data, suggestedFilename: String) throws {
    try validateEditorImageFilename(suggestedFilename)
    guard Int64(data.count) <= MarkdownImageAssetPolicy.maximumFileSizeBytes else {
        throw WorkspaceImageAssetStoreError.importedImageTooLarge(
            suggestedFilename,
            maximumBytes: MarkdownImageAssetPolicy.maximumFileSizeBytes
        )
    }
}

func validateEditorImageFilename(_ filename: String) throws {
    let leafName = URL(fileURLWithPath: filename).lastPathComponent
    guard !filename.utf8.contains(0),
          !leafName.isEmpty,
          leafName != ".",
          MarkdownImageAssetPolicy.isAllowedPathExtension(
              (leafName as NSString).pathExtension
          )
    else {
        throw WorkspaceImageAssetStoreError.unsupportedImageType(filename)
    }
}

var allowedEditorImageTypes: [UTType] {
    MarkdownImageAssetPolicy.allowedPathExtensions.compactMap {
        UTType(filenameExtension: $0)
    }
}

func editorImageAssetFolderComponents(_ path: String) throws -> [String] {
    guard !path.hasPrefix("/"), !path.utf8.contains(0) else {
        throw WorkspaceImageAssetStoreError.assetFolderEscapesWorkspace(path)
    }
    var components: [String] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
        switch component {
        case ".":
            continue
        case "..":
            throw WorkspaceImageAssetStoreError.assetFolderEscapesWorkspace(path)
        default:
            components.append(String(component))
        }
    }
    guard !components.isEmpty else {
        throw WorkspaceImageAssetStoreError.assetFolderEscapesWorkspace(path)
    }
    return components
}

func sanitizedEditorImageFilename(_ filename: String) -> String {
    let leafName = URL(fileURLWithPath: filename).lastPathComponent
    return leafName.isEmpty || leafName == "." ? "image.png" : leafName
}

func uniqueEditorImageFilename(_ filename: String, index: Int) -> String {
    guard index > 0 else { return filename }
    let baseName = (filename as NSString).deletingPathExtension
    let pathExtension = (filename as NSString).pathExtension
    return pathExtension.isEmpty ? "\(baseName)-\(index)" : "\(baseName)-\(index).\(pathExtension)"
}

func editorImageAssetRelativePath(
    folderComponents: [String],
    leafName: String
) -> String {
    (folderComponents + [leafName]).joined(separator: "/")
}

func editorImageRelativePath(
    from directoryComponents: [String],
    to fileComponents: [String]
) -> String {
    let sharedCount = zip(directoryComponents, fileComponents).prefix {
        $0.utf8.elementsEqual($1.utf8)
    }.count
    return (
        Array(repeating: "..", count: directoryComponents.count - sharedCount) +
            Array(fileComponents.dropFirst(sharedCount))
    ).joined(separator: "/")
}

func secureEditorImageRename(
    parentDescriptor: Int32,
    from source: String,
    to destination: String,
    flags: UInt32
) -> Int32 {
    source.withCString { sourcePath in
        destination.withCString { destinationPath in
            Darwin.renameatx_np(
                parentDescriptor,
                sourcePath,
                parentDescriptor,
                destinationPath,
                flags | UInt32(RENAME_NOFOLLOW_ANY)
            )
        }
    }
}

func editorImagePOSIXError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

func editorImageErrorDescription(_ code: Int32) -> String {
    String(cString: Darwin.strerror(code))
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
