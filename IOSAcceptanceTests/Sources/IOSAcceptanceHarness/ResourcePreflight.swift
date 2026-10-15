import CryptoKit
import Darwin
import Foundation

public struct ResourceRecord: Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String
}

public enum ResourcePreflightError: Error, Equatable {
    case emptyManifest
    case hostilePath(String)
    case missing(String)
    case empty(String)
    case notRegularFile(String)
    case unreadable(String, Int32)
    case hashMismatch(path: String, expected: String, actual: String)
    case unexpectedFile(String)
    case manifestParse(String)
}

public enum ResourcePreflight {
    public static func validate(
        root: URL,
        manifest: String
    ) throws -> [ResourceRecord] {
        let entries = try parse(manifest)
        guard !entries.isEmpty else { throw ResourcePreflightError.emptyManifest }
        var records: [ResourceRecord] = []
        records.reserveCapacity(entries.count)
        for entry in entries {
            let record = try inspect(root: root, relativePath: entry.path)
            if let expected = entry.sha256, expected != record.sha256 {
                throw ResourcePreflightError.hashMismatch(
                    path: entry.path,
                    expected: expected,
                    actual: record.sha256
                )
            }
            records.append(record)
        }
        return records
    }

    /// Every regular file under `directory` must appear in the manifest, and every
    /// manifest path under that directory must exist. Symlinks are rejected.
    public static func validateExactDirectory(
        root: URL,
        directory: String,
        manifest: String
    ) throws -> [ResourceRecord] {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        let records = try validate(root: root, manifest: manifest)
        let listed = Set(records.map(\.relativePath).filter { $0.hasPrefix(prefix) })
        guard !listed.isEmpty else { throw ResourcePreflightError.emptyManifest }
        let directoryURL = try resolve(root: root, relativePath: directory)
        let found = try regularFiles(under: directoryURL, relativeTo: root, prefix: prefix)
        for path in found.subtracting(listed) {
            throw ResourcePreflightError.unexpectedFile(path)
        }
        for path in listed.subtracting(found) {
            throw ResourcePreflightError.missing(path)
        }
        return records.filter { $0.relativePath.hasPrefix(prefix) }
    }

    public static func inspect(root: URL, relativePath: String) throws -> ResourceRecord {
        let descriptor: Int32
        do {
            descriptor = try ContainedPath.openForReading(root: root, relativePath: relativePath)
        } catch let error as ContainedPathError {
            throw preflightError(error)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw ResourcePreflightError.unreadable(relativePath, errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw ResourcePreflightError.notRegularFile(relativePath)
        }
        guard metadata.st_size > 0 else {
            throw ResourcePreflightError.empty(relativePath)
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var byteCount = 0
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw ResourcePreflightError.unreadable(relativePath, errno)
            }
            if count == 0 { break }
            byteCount += count
            hasher.update(data: Data(buffer.prefix(count)))
        }
        guard byteCount == metadata.st_size else {
            throw ResourcePreflightError.unreadable(relativePath, EIO)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ResourceRecord(
            relativePath: relativePath,
            byteCount: byteCount,
            sha256: digest
        )
    }

    static func parse(_ manifest: String) throws -> [(path: String, sha256: String?)] {
        var entries: [(path: String, sha256: String?)] = []
        for raw in manifest.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 1 {
                entries.append((String(parts[0]), nil))
                continue
            }
            guard parts.count == 2 else {
                throw ResourcePreflightError.manifestParse(line)
            }
            let digest = String(parts[0])
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
                throw ResourcePreflightError.manifestParse(line)
            }
            entries.append((String(parts[1]), digest))
        }
        return entries
    }

    private static func preflightError(_ error: ContainedPathError) -> ResourcePreflightError {
        switch error {
        case let .hostile(path):
            .hostilePath(path)
        case let .missing(path):
            .missing(path)
        case let .symlink(path):
            .notRegularFile(path)
        case let .unreadable(path, code):
            .unreadable(path, code)
        }
    }

    static func resolve(root: URL, relativePath: String) throws -> URL {
        if relativePath.isEmpty || relativePath.hasPrefix("/") || relativePath.contains("\0") {
            throw ResourcePreflightError.hostilePath(relativePath)
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            throw ResourcePreflightError.hostilePath(relativePath)
        }
        var url = root.standardizedFileURL
        for part in parts {
            url.append(component: part)
        }
        let rootPath = root.standardizedFileURL.path
        let resolved = url.standardizedFileURL.path
        guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
            throw ResourcePreflightError.hostilePath(relativePath)
        }
        return url
    }

    private static func regularFiles(
        under directory: URL,
        relativeTo root: URL,
        prefix: String
    ) throws -> Set<String> {
        var found: Set<String> = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw ResourcePreflightError.missing(prefix)
        }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw ResourcePreflightError.notRegularFile(relativePath(url, rootPath: rootPath))
            }
            guard values.isRegularFile == true else { continue }
            let relative = relativePath(url, rootPath: rootPath)
            guard relative.hasPrefix(prefix) else {
                throw ResourcePreflightError.unexpectedFile(relative)
            }
            found.insert(relative)
        }
        return found
    }

    private static func relativePath(_ url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        let suffix = path.dropFirst(rootPath.count)
        return String(suffix.drop { $0 == "/" })
    }
}
