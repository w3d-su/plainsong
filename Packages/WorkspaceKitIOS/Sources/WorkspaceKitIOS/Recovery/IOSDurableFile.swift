import Darwin
import Foundation

enum IOSDurableFile {
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let tempPath = tempURL.path
        let fd = open(tempPath, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        if fd < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var renameSucceeded = false
        defer {
            if !renameSucceeded {
                _ = unlink(tempPath)
            }
            close(fd)
        }
        try writeAll(data, fd: fd)
        if fsync(fd) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if rename(tempPath, url.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        renameSucceeded = true
        let directoryFD = open(directory.path, O_RDONLY)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            close(directoryFD)
        }
    }

    private static func writeAll(_ data: Data, fd: Int32) throws {
        var remaining = data
        while !remaining.isEmpty {
            let count = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(fd, base, buffer.count)
            }
            if count < 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                throw POSIXError(.EIO)
            }
            remaining.removeFirst(count)
        }
    }
}
