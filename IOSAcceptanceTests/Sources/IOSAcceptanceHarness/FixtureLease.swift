import Darwin
import Foundation

public enum FixtureLeaseError: Error, Equatable {
    case hostilePath(String)
    case missingOwnership
    case foreignToken
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
        let url = try Self.resolve(root: root, relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return url
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

    static func resolve(root: URL, relativePath: String) throws -> URL {
        if relativePath.isEmpty || relativePath.hasPrefix("/") || relativePath.contains("\0") {
            throw FixtureLeaseError.hostilePath(relativePath)
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            throw FixtureLeaseError.hostilePath(relativePath)
        }
        var url = root.standardizedFileURL
        for part in parts {
            url.append(component: part)
        }
        let rootPath = root.standardizedFileURL.path
        let resolved = url.standardizedFileURL.path
        guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
            throw FixtureLeaseError.hostilePath(relativePath)
        }
        return url
    }
}
