import Darwin
import Foundation

public enum FixtureLeaseError: Error, Equatable {
    case hostilePath(String)
    case symlinkEscape(String)
    case missingOwnership
    case foreignToken
    case unreadable(String, Int32)
}

/// A temporary root owned by one acceptance task. Cleanup deletes only a directory
/// whose marker names this lease.
public final class FixtureLease: @unchecked Sendable {
    public let root: URL
    public let token: UUID
    private var cleaned = false

    public init() throws {
        let token = UUID()
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = parent.appendingPathComponent(
            "plainsong-ios-acceptance-\(token.uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data(token.uuidString.utf8).write(to: root.appendingPathComponent(".plainsong-lease"))
        self.token = token
        self.root = root
    }

    public func write(relativePath: String, data: Data) throws -> URL {
        do {
            try ContainedPath.write(root: root, relativePath: relativePath, data: data)
        } catch let error as ContainedPathError {
            throw Self.leaseError(error)
        }
        return Self.lexicalURL(root: root, relativePath: relativePath)
    }

    public func cleanup() throws {
        if cleaned { return }
        try Self.removeIfOwned(root: root, token: token)
        cleaned = true
    }

    public static func removeIfOwned(root: URL, token: UUID) throws {
        let marker = root.appendingPathComponent(".plainsong-lease")
        let descriptor = open(marker.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FixtureLeaseError.missingOwnership }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw FixtureLeaseError.missingOwnership
        }
        let stored = try String(contentsOf: marker, encoding: .utf8)
        guard stored == token.uuidString else { throw FixtureLeaseError.foreignToken }
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL.path
        let path = root.standardizedFileURL.path
        guard path.hasPrefix(parent), path.contains("plainsong-ios-acceptance-") else {
            throw FixtureLeaseError.missingOwnership
        }
        try FileManager.default.removeItem(at: root)
    }

    private static func leaseError(_ error: ContainedPathError) -> FixtureLeaseError {
        switch error {
        case let .hostile(path):
            .hostilePath(path)
        case let .symlink(path):
            .symlinkEscape(path)
        case let .missing(path):
            .unreadable(path, ENOENT)
        case let .unreadable(path, code):
            .unreadable(path, code)
        }
    }

    private static func lexicalURL(root: URL, relativePath: String) -> URL {
        var url = root
        for part in relativePath.split(separator: "/") {
            url.append(component: String(part))
        }
        return url
    }
}
