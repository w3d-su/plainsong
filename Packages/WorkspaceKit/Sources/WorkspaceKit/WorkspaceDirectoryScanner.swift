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
        // Compatibility-only snapshot callers do not retain an authority. Keep their historic
        // alias resolution; WS3B's authority-bearing `snapshotCapture` below deliberately
        // receives the literal spelling unchanged.
        let root = root.standardizedFileURL
        try Task.checkCancellation()

        return try await withThrowingTaskGroup(of: WorkspaceFileSnapshot.self) { group in
            group.addTask(priority: .utility) {
                let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
                try authority.validateCanonicalBinding()
                let snapshot = try Self.makeSnapshot(
                    root: root,
                    rootAuthority: authority,
                    entryVisitHook: entryVisitHook,
                    preservesLiteralEntrySpelling: false
                )
                try authority.validateCanonicalBinding()
                return snapshot
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
        try Task.checkCancellation()

        return try await withThrowingTaskGroup(of: WorkspaceDirectorySnapshotCapture.self) { group in
            group.addTask(priority: .utility) {
                let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
                try authority.validateCanonicalBinding()
                let snapshot = try Self.makeSnapshot(
                    root: authority.canonicalRootURL,
                    rootAuthority: authority,
                    entryVisitHook: entryVisitHook,
                    preservesLiteralEntrySpelling: true
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
        rootAuthority: WorkspaceFileSystemRootAuthority,
        entryVisitHook: @escaping @Sendable (URL) -> Void,
        preservesLiteralEntrySpelling: Bool
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

            let relativePath = Self.relativePath(
                for: url,
                root: root,
                preservesLiteralEntrySpelling: preservesLiteralEntrySpelling
            )
            guard !relativePath.isEmpty else { continue }
            let location = try rootAuthority.location(relativePath: relativePath)
            let mutationExpectation = try WorkspaceNoFollowItemInspector.inspect(at: location)

            entries.append(
                WorkspaceFileSnapshot.Entry(
                    relativePath: relativePath,
                    kind: WorkspaceFileKind(
                        url: url,
                        isDirectory: mutationExpectation.kind == .directory
                    ),
                    identity: Self.identity(from: mutationExpectation),
                    contentModificationDate: values.contentModificationDate,
                    mutationExpectation: mutationExpectation
                )
            )
        }

        try Task.checkCancellation()
        return WorkspaceFileSnapshot(entries: entries)
    }

    static func relativePath(
        for url: URL,
        root: URL,
        preservesLiteralEntrySpelling: Bool
    ) -> String {
        // Strip only separator syntax; unlike `standardizedFileURL`, this preserves every
        // Unicode code unit in the root and entry names.
        let rootPath = WorkspaceRootContainment.normalizedDirectoryPath(
            root.path(percentEncoded: false)
        )
        let filePath = WorkspaceRootContainment.normalizedDirectoryPath(
            (preservesLiteralEntrySpelling ? url : url.standardizedFileURL)
                .path(percentEncoded: false)
        )
        return WorkspaceLiteralFileURL.relativePath(of: filePath, containedIn: rootPath) ?? ""
    }

    private static func identity(from expectation: WorkspaceItemMutationExpectation) -> String {
        let kind = switch expectation.kind {
        case .regularFile:
            "file"
        case .directory:
            "directory"
        case .symbolicLink:
            "symlink"
        case .other:
            "other"
        }
        return "fs:\(expectation.identity.device):\(expectation.identity.inode):\(kind)"
    }
}
