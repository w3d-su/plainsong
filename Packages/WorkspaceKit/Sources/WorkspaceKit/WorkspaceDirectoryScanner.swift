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

/// One off-main reload result whose snapshot and filesystem authority are installed together.
public struct WorkspaceDirectorySnapshotCapture: Sendable {
    public let snapshot: WorkspaceFileSnapshot
    public let rootAuthority: WorkspaceFileSystemRootAuthority

    public init(
        snapshot: WorkspaceFileSnapshot,
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) {
        self.snapshot = snapshot
        self.rootAuthority = rootAuthority
    }
}

public struct WorkspaceDirectoryScanner: Sendable {
    private let entryVisitHook: @Sendable (URL) -> Void

    public init() {
        entryVisitHook = { _ in }
    }

    init(entryVisitHook: @escaping @Sendable (URL) -> Void) {
        self.entryVisitHook = entryVisitHook
    }

    public func snapshot(root: URL) async throws -> WorkspaceFileSnapshot {
        let root = root.standardizedFileURL
        try Task.checkCancellation()

        return try await withThrowingTaskGroup(of: WorkspaceFileSnapshot.self) { group in
            group.addTask(priority: .utility) {
                try Self.makeSnapshot(root: root, entryVisitHook: entryVisitHook)
            }
            defer { group.cancelAll() }

            guard let snapshot = try await group.next() else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            return snapshot
        }
    }

    /// Captures root authority and enumerates its canonical spelling on the same utility task.
    /// Namespace replacement during enumeration rejects the whole capture.
    public func snapshotCapture(root: URL) async throws -> WorkspaceDirectorySnapshotCapture {
        let root = root.standardizedFileURL
        try Task.checkCancellation()

        return try await withThrowingTaskGroup(of: WorkspaceDirectorySnapshotCapture.self) { group in
            group.addTask(priority: .utility) {
                let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
                try authority.validateCanonicalBinding()
                let snapshot = try Self.makeSnapshot(
                    root: authority.canonicalRootURL,
                    entryVisitHook: entryVisitHook
                )
                try authority.validateCanonicalBinding()
                return WorkspaceDirectorySnapshotCapture(
                    snapshot: snapshot,
                    rootAuthority: authority
                )
            }
            defer { group.cancelAll() }

            guard let capture = try await group.next() else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            return capture
        }
    }

    private static func makeSnapshot(
        root: URL,
        entryVisitHook: @escaping @Sendable (URL) -> Void
    ) throws -> WorkspaceFileSnapshot {
        try Task.checkCancellation()
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
            try Task.checkCancellation()
            entryVisitHook(url)
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            try Task.checkCancellation()
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

        try Task.checkCancellation()
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
