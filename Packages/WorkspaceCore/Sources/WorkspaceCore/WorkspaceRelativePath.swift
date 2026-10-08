import Foundation

public enum WorkspaceRelativePathRejection: Equatable, Sendable {
    case emptyLeaf
    case absolutePath
    case nulByte
    case parentTraversal
}

/// A lexical relative path. The stored spelling is the caller's bytes.
///
/// This parser rejects hostile forms. It does not rewrite `/etc/a.md` into
/// `etc/a.md`, and it does not resolve symlinks or consult the filesystem.
public struct WorkspaceRelativePath: Hashable, Sendable {
    public let spelling: String

    public var byteKey: WorkspacePathByteKey {
        WorkspacePathByteKey(spelling)
    }

    public static func == (lhs: WorkspaceRelativePath, rhs: WorkspaceRelativePath) -> Bool {
        lhs.byteKey == rhs.byteKey
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(byteKey)
    }

    public init?(spelling: String) {
        guard Self.rejection(for: spelling) == nil else { return nil }
        self.spelling = spelling
    }

    public static func rejection(for path: String) -> WorkspaceRelativePathRejection? {
        if path.isEmpty {
            return .emptyLeaf
        }
        if path.hasPrefix("/") {
            return .absolutePath
        }
        if path.utf8.contains(0) {
            return .nulByte
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0 == ".." }) {
            return .parentTraversal
        }
        if components.isEmpty || components.contains(where: { $0.isEmpty || $0 == "." }) {
            return .emptyLeaf
        }
        return nil
    }
}

/// Root is a distinct marker. An empty leaf is not a root and does not parse.
public enum WorkspaceTreeLocation: Hashable, Sendable {
    case root
    case relative(WorkspaceRelativePath)

    public static func file(spelling: String) -> WorkspaceTreeLocation? {
        guard let path = WorkspaceRelativePath(spelling: spelling) else { return nil }
        return .relative(path)
    }

    public var relativeSpelling: String? {
        switch self {
        case .root:
            nil
        case let .relative(path):
            path.spelling
        }
    }
}
