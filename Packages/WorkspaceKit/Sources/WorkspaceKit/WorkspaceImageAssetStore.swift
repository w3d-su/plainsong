import Foundation
import MarkdownCore
import UniformTypeIdentifiers
import WorkspaceCore

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
    public static let defaultMaximumImportedImageSizeBytes = MarkdownImageAssetPolicy.maximumFileSizeBytes

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
        // A security scope belongs to the URL the caller resolved; a standardized copy does not carry it.
        let scopedRootURL = rootURL
        let rootURL = rootURL.standardizedFileURL
        let currentFileURL = currentFileURL.standardizedFileURL

        return try SecurityScopedAccess.withAccess(to: scopedRootURL) {
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
                    try FileManager.default.createDirectory(
                        at: assetDirectoryURL,
                        withIntermediateDirectories: true
                    )
                    let destinationURL = try createUniqueFile(
                        named: filename,
                        in: assetDirectoryURL,
                        contents: data
                    )
                    try insertedPaths.append(copiedAssetRelativePath(
                        from: currentDirectoryURL,
                        to: destinationURL,
                        rootURL: rootURL
                    ))

                case let .file(scopedSourceURL):
                    let sourceURL = scopedSourceURL.standardizedFileURL
                    let resolvedSourceURL = sourceURL.resolvingSymlinksInPath()

                    if Self.isContained(sourceURL, in: rootURL) {
                        try validateImageFile(at: resolvedSourceURL)
                        insertedPaths.append(Self.relativePath(from: currentDirectoryURL, to: sourceURL))
                        continue
                    }

                    try SecurityScopedAccess.withAccess(to: scopedSourceURL) {
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
        guard !assetFolderRelativePath.hasLeadingPathSeparator,
              !assetFolderRelativePath
              .splitOnPathSeparator(omittingEmptySubsequences: false)
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
        for candidateName in Self.candidateFilenames(for: filename) {
            let candidateURL = directoryURL.appendingPathComponent(candidateName, isDirectory: false)
            if !Self.entryExists(at: candidateURL) {
                return candidateURL
            }
        }
        throw WorkspaceImageAssetStoreError.couldNotCreateAssetFile(filename)
    }

    /// Creates the file with `O_EXCL | O_NOFOLLOW`, so a symlink planted at the
    /// chosen name, dangling or not, is a taken name and never a write target.
    func createUniqueFile(named filename: String, in directoryURL: URL, contents: Data) throws -> URL {
        for candidateName in Self.candidateFilenames(for: filename) {
            let candidateURL = directoryURL.appendingPathComponent(candidateName, isDirectory: false)
            let descriptor = Darwin.open(
                candidateURL.path(percentEncoded: false),
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o644
            )
            guard descriptor >= 0 else {
                if errno == EEXIST {
                    continue
                }
                throw WorkspaceImageAssetStoreError.couldNotCreateAssetFile(candidateName)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: contents)
                try handle.close()
            } catch {
                try? FileManager.default.removeItem(at: candidateURL)
                throw WorkspaceImageAssetStoreError.couldNotCreateAssetFile(candidateName)
            }
            return candidateURL
        }
        throw WorkspaceImageAssetStoreError.couldNotCreateAssetFile(filename)
    }

    static func candidateFilenames(for filename: String) -> some Sequence<String> {
        let baseName = (filename as NSString).deletingPathExtension
        let pathExtension = (filename as NSString).pathExtension
        return sequence(first: 0) { $0 + 1 }.lazy.map { index in
            if index == 0 {
                filename
            } else if pathExtension.isEmpty {
                "\(baseName)-\(index)"
            } else {
                "\(baseName)-\(index).\(pathExtension)"
            }
        }
    }

    /// `lstat`, unlike `fileExists`, also reports a dangling symlink as an existing entry.
    static func entryExists(at url: URL) -> Bool {
        var status = stat()
        return Darwin.lstat(url.path(percentEncoded: false), &status) == 0 || errno != ENOENT
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
        MarkdownImageAssetPolicy.allowedPathExtensions.compactMap { pathExtension in
            UTType(filenameExtension: pathExtension)
        }
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
        WorkspaceRootContainment.isContained(url, in: rootURL)
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
            .splitOnPathSeparator(omittingEmptySubsequences: false)
            .contains("..")
    }
}
