import Foundation

public enum WorkspaceImageAssetSource: Equatable, Sendable {
    case data(Data, suggestedFilename: String)
    case file(URL)
}

public enum WorkspaceImageAssetStoreError: LocalizedError, Equatable {
    case currentFileOutsideWorkspace(URL)
    case assetFolderEscapesWorkspace(String)
    case couldNotCreateAssetFile(String)

    public var errorDescription: String? {
        switch self {
        case let .currentFileOutsideWorkspace(url):
            "\(url.lastPathComponent) is outside the open workspace."
        case let .assetFolderEscapesWorkspace(path):
            "The asset folder path \(path) escapes the open workspace."
        case let .couldNotCreateAssetFile(filename):
            "Could not create \(filename) in the asset folder."
        }
    }
}

public struct WorkspaceImageAssetStore: Sendable {
    public let assetFolderRelativePath: String

    public init(assetFolderRelativePath: String = "assets") {
        self.assetFolderRelativePath = assetFolderRelativePath
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
                    insertedPaths.append(Self.relativePath(from: currentDirectoryURL, to: destinationURL))

                case let .file(sourceURL):
                    let sourceURL = sourceURL.standardizedFileURL
                    if Self.isContained(sourceURL, in: rootURL) {
                        insertedPaths.append(Self.relativePath(from: currentDirectoryURL, to: sourceURL))
                        continue
                    }

                    try FileManager.default.createDirectory(
                        at: assetDirectoryURL,
                        withIntermediateDirectories: true
                    )
                    let destinationURL = try uniqueDestinationURL(
                        named: sanitizedFilename(sourceURL.lastPathComponent),
                        in: assetDirectoryURL
                    )
                    try SecurityScopedAccess.withAccess(to: sourceURL) {
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    }
                    insertedPaths.append(Self.relativePath(from: currentDirectoryURL, to: destinationURL))
                }
            }

            return insertedPaths
        }
    }
}

private extension WorkspaceImageAssetStore {
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

    static func normalizedDirectoryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
