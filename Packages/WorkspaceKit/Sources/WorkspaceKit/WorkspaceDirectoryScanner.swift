import Foundation

public enum WorkspaceDirectoryScannerError: LocalizedError, Equatable {
    case rootIsNotDirectory(URL)
    case cannotEnumerate(URL)

    public var errorDescription: String? {
        switch self {
        case let .rootIsNotDirectory(url):
            "\(url.lastPathComponent) is not a folder."
        case let .cannotEnumerate(url):
            "Could not read the contents of \(url.lastPathComponent)."
        }
    }
}

public struct WorkspaceDirectoryScanner: Sendable {
    public init() {}

    public func snapshot(root: URL) async throws -> WorkspaceFileSnapshot {
        let root = root.standardizedFileURL
        return try await Task.detached(priority: .utility) {
            try Self.makeSnapshot(root: root)
        }.value
    }

    private static func makeSnapshot(root: URL) throws -> WorkspaceFileSnapshot {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw WorkspaceDirectoryScannerError.rootIsNotDirectory(root)
        }

        let keys: [URLResourceKey] = [
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .isDirectoryKey,
            .isHiddenKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw WorkspaceDirectoryScannerError.cannotEnumerate(root)
        }

        var entries: [WorkspaceFileSnapshot.Entry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isHidden == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let relativePath = Self.relativePath(for: url, root: root)
            guard !relativePath.isEmpty else { continue }

            entries.append(
                WorkspaceFileSnapshot.Entry(
                    relativePath: relativePath,
                    kind: WorkspaceFileKind(url: url, isDirectory: values.isDirectory == true),
                    identity: Self.identity(from: values.fileResourceIdentifier, fallback: relativePath),
                    contentModificationDate: values.contentModificationDate
                )
            )
        }

        return WorkspaceFileSnapshot(entries: entries)
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.path(percentEncoded: false)
        let filePath = url.standardizedFileURL.path(percentEncoded: false)
        guard filePath.hasPrefix(rootPath) else { return "" }

        var relativePath = String(filePath.dropFirst(rootPath.count))
        if relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }
        return relativePath
    }

    private static func identity(from identifier: Any?, fallback: String) -> String {
        guard let identifier else {
            return fallback
        }
        return String(describing: identifier)
    }
}
