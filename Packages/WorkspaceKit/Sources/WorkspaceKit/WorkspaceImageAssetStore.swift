import Foundation
import UniformTypeIdentifiers

public enum WorkspaceImageAssetSource: Equatable, Sendable {
    case data(Data, suggestedFilename: String)
    case file(URL)
}

public enum WorkspaceImageAssetStoreError: LocalizedError, Equatable {
    case currentFileOutsideWorkspace(URL)
    case assetFolderEscapesWorkspace(String)
    case unsupportedImageType(String)
    case importedImageTooLarge(String, maximumBytes: Int64)
    case couldNotCreateAssetFile(String)

    public var errorDescription: String? {
        switch self {
        case let .currentFileOutsideWorkspace(url):
            "\(url.lastPathComponent) is outside the open workspace."
        case let .assetFolderEscapesWorkspace(path):
            "The asset folder path \(path) escapes the open workspace."
        case let .unsupportedImageType(filename):
            "\(filename) is not a supported image type. Use PNG, JPEG, GIF, or WebP."
        case let .importedImageTooLarge(filename, maximumBytes):
            "\(filename) is larger than the \(Self.formattedByteLimit(maximumBytes)) image import limit."
        case let .couldNotCreateAssetFile(filename):
            "Could not create \(filename) in the asset folder."
        }
    }

    private static func formattedByteLimit(_ bytes: Int64) -> String {
        let mebibyte = 1024 * 1024
        guard bytes % Int64(mebibyte) == 0 else {
            return "\(bytes) byte"
        }
        return "\(bytes / Int64(mebibyte)) MiB"
    }
}

public struct WorkspaceImageAssetStore: Sendable {
    public static let defaultMaximumImportedImageSizeBytes: Int64 = 10 * 1024 * 1024

    public let assetFolderRelativePath: String
    public let maximumImportedImageSizeBytes: Int64
    private let copyFile: @Sendable (URL, URL) throws -> Void

    public init(
        assetFolderRelativePath: String = "assets",
        maximumImportedImageSizeBytes: Int64 = Self.defaultMaximumImportedImageSizeBytes
    ) {
        self.init(
            assetFolderRelativePath: assetFolderRelativePath,
            maximumImportedImageSizeBytes: maximumImportedImageSizeBytes,
            copyFile: Self.defaultCopyFile
        )
    }

    init(
        assetFolderRelativePath: String = "assets",
        maximumImportedImageSizeBytes: Int64 = Self.defaultMaximumImportedImageSizeBytes,
        copyFile: @escaping @Sendable (URL, URL) throws -> Void
    ) {
        self.assetFolderRelativePath = assetFolderRelativePath
        self.maximumImportedImageSizeBytes = maximumImportedImageSizeBytes
        self.copyFile = copyFile
    }

    public func place(
        _ sources: [WorkspaceImageAssetSource],
        rootURL: URL,
        currentFileURL: URL
    ) throws -> [String] {
        let rootURL = rootURL.standardizedFileURL
        let currentFileURL = currentFileURL.standardizedFileURL

        return try SecurityScopedAccess.withAccess(to: rootURL) {
            guard Self.isContained(currentFileURL, in: rootURL) else {
                throw WorkspaceImageAssetStoreError.currentFileOutsideWorkspace(currentFileURL)
            }

            let currentDirectoryURL = currentFileURL.deletingLastPathComponent()
            let assetDirectoryURL = try containedAssetDirectoryURL(
                currentDirectoryURL: currentDirectoryURL,
                rootURL: rootURL
            )

            var insertedPaths: [String] = []
            for source in sources {
                switch source {
                case let .data(data, suggestedFilename):
                    try validateImageData(data, suggestedFilename: suggestedFilename)

                    let filename = sanitizedFilename(suggestedFilename)
                    let destinationURL = try uniqueDestinationURL(
                        named: filename,
                        in: assetDirectoryURL
                    )
                    try FileManager.default.createDirectory(
                        at: assetDirectoryURL,
                        withIntermediateDirectories: true
                    )
                    guard FileManager.default.createFile(
                        atPath: destinationURL.path(percentEncoded: false),
                        contents: data
                    ) else {
                        throw WorkspaceImageAssetStoreError.couldNotCreateAssetFile(destinationURL.lastPathComponent)
                    }
                    try insertedPaths.append(copiedAssetRelativePath(
                        from: currentDirectoryURL,
                        to: destinationURL,
                        rootURL: rootURL
                    ))

                case let .file(sourceURL):
                    let sourceURL = sourceURL.standardizedFileURL
                    let resolvedSourceURL = sourceURL.resolvingSymlinksInPath()

                    if Self.isContained(sourceURL, in: rootURL) {
                        try validateImageFile(at: resolvedSourceURL)
                        insertedPaths.append(Self.relativePath(from: currentDirectoryURL, to: sourceURL))
                        continue
                    }

                    try SecurityScopedAccess.withAccess(to: sourceURL) {
                        try validateImageFile(at: resolvedSourceURL)
                        try FileManager.default.createDirectory(
                            at: assetDirectoryURL,
                            withIntermediateDirectories: true
                        )
                        let destinationURL = try uniqueDestinationURL(
                            named: sanitizedFilename(resolvedSourceURL.lastPathComponent),
                            in: assetDirectoryURL
                        )
                        try copyFile(resolvedSourceURL, destinationURL)
                        try insertedPaths.append(copiedAssetRelativePath(
                            from: currentDirectoryURL,
                            to: destinationURL,
                            rootURL: rootURL
                        ))
                    }
                }
            }

            return insertedPaths
        }
    }
}

private extension WorkspaceImageAssetStore {
    static let defaultCopyFile: @Sendable (URL, URL) throws -> Void = { sourceURL, destinationURL in
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    func containedAssetDirectoryURL(currentDirectoryURL: URL, rootURL: URL) throws -> URL {
        guard !assetFolderRelativePath.hasPrefix("/"),
              !assetFolderRelativePath
              .split(separator: "/", omittingEmptySubsequences: false)
              .contains("..")
        else {
            throw WorkspaceImageAssetStoreError.assetFolderEscapesWorkspace(assetFolderRelativePath)
        }

        let directoryURL = currentDirectoryURL
            .appendingPathComponent(assetFolderRelativePath, isDirectory: true)
            .standardizedFileURL
        guard Self.isContained(directoryURL, in: rootURL) else {
            throw WorkspaceImageAssetStoreError.assetFolderEscapesWorkspace(assetFolderRelativePath)
        }
        return directoryURL
    }

    func uniqueDestinationURL(named filename: String, in directoryURL: URL) throws -> URL {
        let proposedURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: proposedURL.path(percentEncoded: false)) else {
            return proposedURL
        }

        let baseName = (filename as NSString).deletingPathExtension
        let pathExtension = (filename as NSString).pathExtension
        for index in 1 ..< Int.max {
            let candidateName = if pathExtension.isEmpty {
                "\(baseName)-\(index)"
            } else {
                "\(baseName)-\(index).\(pathExtension)"
            }
            let candidateURL = directoryURL.appendingPathComponent(candidateName, isDirectory: false)
            if !FileManager.default.fileExists(atPath: candidateURL.path(percentEncoded: false)) {
                return candidateURL
            }
        }

        throw WorkspaceImageAssetStoreError.couldNotCreateAssetFile(filename)
    }

    func sanitizedFilename(_ filename: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: filename).lastPathComponent
        guard !lastPathComponent.isEmpty, lastPathComponent != "." else {
            return "image.png"
        }
        return lastPathComponent
    }

    func validateImageData(_ data: Data, suggestedFilename: String) throws {
        let filename = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        guard !filename.isEmpty, filename != "." else {
            throw WorkspaceImageAssetStoreError.unsupportedImageType(suggestedFilename)
        }
        try validateAllowedImageType(filename: filename, metadataContentType: nil)
        try validateImageByteCount(Int64(data.count), filename: filename)
    }

    func validateImageFile(at url: URL) throws {
        let metadata = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
        guard metadata.isRegularFile == true else {
            throw WorkspaceImageAssetStoreError.unsupportedImageType(url.lastPathComponent)
        }
        try validateAllowedImageType(filename: url.lastPathComponent, metadataContentType: metadata.contentType)
        guard let fileSize = metadata.fileSize else {
            throw WorkspaceImageAssetStoreError.unsupportedImageType(url.lastPathComponent)
        }
        try validateImageByteCount(Int64(fileSize), filename: url.lastPathComponent)
    }

    func validateAllowedImageType(filename: String, metadataContentType: UTType?) throws {
        guard let extensionType = UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension),
              Self.isAllowedImportedImageType(extensionType)
        else {
            throw WorkspaceImageAssetStoreError.unsupportedImageType(filename)
        }

        if let metadataContentType,
           !Self.isAllowedImportedImageType(metadataContentType)
        {
            throw WorkspaceImageAssetStoreError.unsupportedImageType(filename)
        }
    }

    func validateImageByteCount(_ byteCount: Int64, filename: String) throws {
        guard byteCount <= maximumImportedImageSizeBytes else {
            throw WorkspaceImageAssetStoreError.importedImageTooLarge(
                filename,
                maximumBytes: maximumImportedImageSizeBytes
            )
        }
    }

    static func isAllowedImportedImageType(_ type: UTType) -> Bool {
        allowedImportedImageTypes.contains { type.conforms(to: $0) }
    }

    static var allowedImportedImageTypes: [UTType] {
        [.png, .jpeg, .gif, .webP]
    }

    func copiedAssetRelativePath(from directoryURL: URL, to destinationURL: URL, rootURL: URL) throws -> String {
        guard Self.isContained(destinationURL, in: rootURL) else {
            throw WorkspaceImageAssetStoreError.couldNotCreateAssetFile(destinationURL.lastPathComponent)
        }

        let relativePath = Self.relativePath(from: directoryURL, to: destinationURL)
        guard !Self.containsParentDirectoryComponent(relativePath) else {
            throw WorkspaceImageAssetStoreError.couldNotCreateAssetFile(destinationURL.lastPathComponent)
        }
        return relativePath
    }

    static func isContained(_ url: URL, in rootURL: URL) -> Bool {
        let candidatePath = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let rootPath = normalizedDirectoryPath(rootURL)
        return candidatePath == rootPath || candidatePath.hasPrefix("\(rootPath)/")
    }

    static func relativePath(from directoryURL: URL, to fileURL: URL) -> String {
        let directoryComponents = directoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .pathComponents
        let fileComponents = fileURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .pathComponents

        let sharedCount = zip(directoryComponents, fileComponents).prefix { $0 == $1 }.count
        let parentComponents = Array(repeating: "..", count: directoryComponents.count - sharedCount)
        let targetComponents = Array(fileComponents.dropFirst(sharedCount))
        return (parentComponents + targetComponents).joined(separator: "/")
    }

    static func containsParentDirectoryComponent(_ path: String) -> Bool {
        path
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains("..")
    }

    static func normalizedDirectoryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
