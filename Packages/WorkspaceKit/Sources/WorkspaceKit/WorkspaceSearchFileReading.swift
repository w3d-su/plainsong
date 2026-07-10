import Foundation

/// Sendable boundary for bounded search reads. Tests can inject failures, delays, and order.
public protocol WorkspaceSearchFileReading: Sendable {
    /// Returns no more than `maximumByteCount` bytes.
    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data
}

/// Optional typed errors for injected readers. Other read errors are reported as unreadable.
public enum WorkspaceSearchFileReadError: Error, Sendable, Equatable {
    case disappeared
    case unreadable
}

/// FileHandle-based bounded reader used by production workspace search.
public struct WorkspaceSearchDiskFileReader: WorkspaceSearchFileReading {
    public init() {}

    public func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let data = try handle.read(upToCount: max(0, maximumByteCount)) ?? Data()
        try Task.checkCancellation()
        return data
    }
}
