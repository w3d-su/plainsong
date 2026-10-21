import Darwin
import Foundation

enum ContainedPathError: Error, Equatable {
    case hostile(String)
    case missing(String)
    case symlink(String)
    case unreadable(String, Int32)
}

/// Opens and writes a relative path one component at a time from a directory
/// descriptor. `O_NOFOLLOW` on a full path only rejects a symlink leaf, so each
/// ancestor is opened with `O_DIRECTORY | O_NOFOLLOW`. On this OS a symlink
/// opened that way fails with `ENOTDIR`; a symlink leaf fails with `ELOOP`.
enum ContainedPath {
    static func openForReading(root: URL, relativePath: String) throws -> Int32 {
        let parts = try components(relativePath)
        let (parent, leaf) = try walkParents(root: root, parts: parts, create: false)
        defer { parent.close() }
        return try openFile(parent: parent.raw, name: leaf, path: relativePath)
    }

    static func write(root: URL, relativePath: String, data: Data) throws {
        let parts = try components(relativePath)
        let (parent, leaf) = try walkParents(root: root, parts: parts, create: true)
        defer { parent.close() }
        try writeAtomic(parent: parent.raw, leaf: leaf, path: relativePath, data: data)
    }

    static func components(_ relativePath: String) throws -> [String] {
        if relativePath.isEmpty || relativePath.hasPrefix("/") || relativePath.contains("\0") {
            throw ContainedPathError.hostile(relativePath)
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) {
            throw ContainedPathError.hostile(relativePath)
        }
        return parts
    }

    private static func walkParents(
        root: URL,
        parts: [String],
        create: Bool
    ) throws -> (DirectoryHandle, String) {
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw ContainedPathError.unreadable(parts.joined(separator: "/"), errno)
        }
        var current = DirectoryHandle(rootFD)
        for (index, part) in parts.dropLast().enumerated() {
            let path = parts.prefix(index + 1).joined(separator: "/")
            let next = try openOrCreateDirectory(
                parent: current.raw,
                name: part,
                path: path,
                create: create
            )
            current.close()
            current = next
        }
        return (current, parts[parts.count - 1])
    }

    private static func openOrCreateDirectory(
        parent: Int32,
        name: String,
        path: String,
        create: Bool
    ) throws -> DirectoryHandle {
        switch try probeDirectory(parent: parent, name: name, path: path) {
        case let .opened(fd):
            return DirectoryHandle(fd)
        case .absent:
            guard create else { throw ContainedPathError.missing(path) }
        }
        let createError = name.withCString { pointer -> Int32 in
            if mkdirat(parent, pointer, S_IRWXU) == 0 { return 0 }
            return errno
        }
        if createError != 0, createError != EEXIST {
            throw ContainedPathError.unreadable(path, createError)
        }
        switch try probeDirectory(parent: parent, name: name, path: path) {
        case let .opened(fd):
            return DirectoryHandle(fd)
        case .absent:
            throw ContainedPathError.missing(path)
        }
    }

    private static func probeDirectory(
        parent: Int32,
        name: String,
        path: String
    ) throws -> ChildDirectory {
        try name.withCString { pointer in
            let fd = openat(parent, pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 { return .opened(fd) }
            switch errno {
            case ENOENT:
                return .absent
            case ELOOP, ENOTDIR:
                throw ContainedPathError.symlink(path)
            default:
                throw ContainedPathError.unreadable(path, errno)
            }
        }
    }

    private static func openFile(parent: Int32, name: String, path: String) throws -> Int32 {
        try name.withCString { pointer in
            let fd = openat(parent, pointer, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 { return fd }
            switch errno {
            case ENOENT:
                throw ContainedPathError.missing(path)
            case ELOOP, ENOTDIR:
                throw ContainedPathError.symlink(path)
            default:
                throw ContainedPathError.unreadable(path, errno)
            }
        }
    }

    private static func writeAtomic(parent: Int32, leaf: String, path: String, data: Data) throws {
        let temporary = ".plainsong-write-\(UUID().uuidString)"
        let fd = try temporary.withCString { pointer -> Int32 in
            let opened = openat(
                parent,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard opened >= 0 else {
                throw ContainedPathError.unreadable(path, errno)
            }
            return opened
        }
        var openFD = fd
        defer {
            if openFD >= 0 { _ = Darwin.close(openFD) }
        }
        do {
            try writeAll(fd: fd, path: path, data: data)
            guard fsync(fd) == 0 else { throw ContainedPathError.unreadable(path, errno) }
            guard Darwin.close(fd) == 0 else {
                openFD = -1
                throw ContainedPathError.unreadable(path, errno)
            }
            openFD = -1
            try temporary.withCString { temporaryPointer in
                try leaf.withCString { leafPointer in
                    guard renameat(parent, temporaryPointer, parent, leafPointer) == 0 else {
                        _ = unlinkat(parent, temporaryPointer, 0)
                        throw ContainedPathError.unreadable(path, errno)
                    }
                }
            }
        } catch {
            _ = temporary.withCString { unlinkat(parent, $0, 0) }
            throw error
        }
    }

    private static func writeAll(fd: Int32, path: String, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var pointer = base
            var remaining = raw.count
            while remaining > 0 {
                let wrote = Darwin.write(fd, pointer, remaining)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw ContainedPathError.unreadable(path, errno)
                }
                remaining -= wrote
                pointer = pointer.advanced(by: wrote)
            }
        }
    }

    private enum ChildDirectory {
        case opened(Int32)
        case absent
    }
}

private final class DirectoryHandle {
    private var fd: Int32

    init(_ fd: Int32) {
        self.fd = fd
    }

    var raw: Int32 {
        fd
    }

    func close() {
        guard fd >= 0 else { return }
        _ = Darwin.close(fd)
        fd = -1
    }

    deinit {
        close()
    }
}
