import Foundation

public struct WorkspaceSearchFileReadResult: Sendable, Equatable {
    public let data: Data
    public let fileAuthority: WorkspaceSearchFileAuthority?

    public init(
        data: Data,
        fileAuthority: WorkspaceSearchFileAuthority?
    ) {
        self.data = data
        self.fileAuthority = fileAuthority
    }
}

/// Sendable boundary for bounded search reads. Tests can inject failures, delays, and order.
public protocol WorkspaceSearchFileReading: Sendable {
    /// Revalidates the resolved physical target immediately before overlay or disk selection.
    /// A `nil` result means the URL is a readable regular file at this instant.
    func physicalPreflightError(at url: URL) -> WorkspaceSearchFileReadError?

    /// Returns no more than `maximumByteCount` bytes.
    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data

    /// Validates one physical target beneath an immutable root authority. Production
    /// implementations must reject every symlink component.
    func validateFile(at location: WorkspaceFileSystemLocation) async throws

    /// Validates and bounded-reads through one opened descriptor or equivalent immutable
    /// authority. Production must not split this into preflight and a later path reopen.
    func readFile(
        at location: WorkspaceFileSystemLocation,
        maximumByteCount: Int
    ) async throws -> Data

    /// Returns the exact descriptor identity used to validate overlay eligibility.
    /// Compatibility readers may return `nil`; the production reader never does.
    func validateFileAuthority(
        at location: WorkspaceFileSystemLocation
    ) async throws -> WorkspaceSearchFileAuthority?

    /// Returns bounded bytes and the identity sampled from the same read descriptor.
    /// Compatibility readers may omit authority; the production reader never does.
    func readFileWithAuthority(
        at location: WorkspaceFileSystemLocation,
        maximumByteCount: Int
    ) async throws -> WorkspaceSearchFileReadResult
}

public extension WorkspaceSearchFileReading {
    func physicalPreflightError(at url: URL) -> WorkspaceSearchFileReadError? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .disappeared
        }
        guard FileManager.default.isReadableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else {
            return .unreadable
        }
        return nil
    }

    func validateFile(at location: WorkspaceFileSystemLocation) async throws {
        switch WorkspaceNoFollowFileInspector.status(at: location) {
        case .regular:
            break
        case .missing:
            throw WorkspaceSearchFileReadError.disappeared
        case .symbolicLink:
            throw WorkspaceSearchFileReadError.symbolicLink
        case .notRegularFile:
            throw WorkspaceSearchFileReadError.notRegularFile
        case .unreadable:
            throw WorkspaceSearchFileReadError.unreadable
        }
        if let error = physicalPreflightError(at: location.fileURL) {
            throw error
        }
    }

    func readFile(
        at location: WorkspaceFileSystemLocation,
        maximumByteCount: Int
    ) async throws -> Data {
        try await readFile(at: location.fileURL, maximumByteCount: maximumByteCount)
    }

    func validateFileAuthority(
        at location: WorkspaceFileSystemLocation
    ) async throws -> WorkspaceSearchFileAuthority? {
        try await validateFile(at: location)
        return nil
    }

    func readFileWithAuthority(
        at location: WorkspaceFileSystemLocation,
        maximumByteCount: Int
    ) async throws -> WorkspaceSearchFileReadResult {
        let data = try await readFile(
            at: location,
            maximumByteCount: maximumByteCount
        )
        return WorkspaceSearchFileReadResult(data: data, fileAuthority: nil)
    }
}

/// Optional typed errors for injected readers. Other read errors are reported as unreadable.
public enum WorkspaceSearchFileReadError: Error, Sendable, Equatable {
    case disappeared
    case unreadable
    case symbolicLink
    case notRegularFile
}

/// FileHandle-based bounded reader used by production workspace search.
public struct WorkspaceSearchDiskFileReader: WorkspaceSearchFileReading {
    let retryLimit: Int
    let eventHandler: (@Sendable (Event) -> Void)?

    public init() {
        retryLimit = 3
        eventHandler = nil
    }

    init(
        retryLimit: Int = 3,
        eventHandler: @escaping @Sendable (Event) -> Void
    ) {
        self.retryLimit = max(1, retryLimit)
        self.eventHandler = eventHandler
    }

    public func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        let location = try WorkspaceFileSystemLocation(fileURL: url)
        return try await readFile(at: location, maximumByteCount: maximumByteCount)
    }

    public func validateFile(at location: WorkspaceFileSystemLocation) async throws {
        _ = try await validateFileAuthority(at: location)
    }

    public func validateFileAuthority(
        at location: WorkspaceFileSystemLocation
    ) async throws -> WorkspaceSearchFileAuthority? {
        try Task.checkCancellation()
        do {
            let metadata = try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
                try WorkspaceAnchoredFileSystem.validate(
                    location,
                    hooks: .init(eventHandler: { event in
                        emit(event, attempt: 0, locationPath: location.relativePath)
                    })
                )
            }
            try Task.checkCancellation()
            return WorkspaceSearchFileAuthority(
                location: location,
                identity: metadata.identity
            )
        } catch {
            throw Self.searchError(from: error)
        }
    }

    public func readFile(
        at location: WorkspaceFileSystemLocation,
        maximumByteCount: Int
    ) async throws -> Data {
        try await readFileWithAuthority(
            at: location,
            maximumByteCount: maximumByteCount
        ).data
    }

    public func readFileWithAuthority(
        at location: WorkspaceFileSystemLocation,
        maximumByteCount: Int
    ) async throws -> WorkspaceSearchFileReadResult {
        try Task.checkCancellation()
        do {
            return try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
                for attempt in 0 ..< retryLimit {
                    do {
                        let result = try WorkspaceAnchoredFileSystem.read(
                            location,
                            maximumByteCount: max(0, maximumByteCount),
                            hooks: .init(eventHandler: { event in
                                emit(
                                    event,
                                    attempt: attempt,
                                    locationPath: location.relativePath
                                )
                            })
                        )
                        return WorkspaceSearchFileReadResult(
                            data: result.data,
                            fileAuthority: WorkspaceSearchFileAuthority(
                                location: location,
                                identity: result.metadata.identity
                            )
                        )
                    } catch let error as WorkspaceAnchoredFileSystemError {
                        if error == .unstable, attempt + 1 < retryLimit {
                            eventHandler?(.retry(attempt, location.relativePath))
                            continue
                        }
                        throw error
                    } catch {
                        throw error
                    }
                }
                throw WorkspaceAnchoredFileSystemError.unstable
            }
        } catch {
            throw Self.searchError(from: error)
        }
    }
}

extension WorkspaceSearchDiskFileReader {
    enum Event: Equatable {
        case rootAnchored(Int, String)
        case componentOpened(Int, String, String)
        case parentAnchored(Int, String)
        case fileOpened(Int, String)
        case readChunk(Int, Int, String)
        case postflight(Int, String)
        case retry(Int, String)
    }

    private func emit(
        _ event: WorkspaceAnchoredFileSystem.Event,
        attempt: Int,
        locationPath: String
    ) {
        switch event {
        case .rootAnchored:
            eventHandler?(.rootAnchored(attempt, locationPath))
        case let .componentOpened(component):
            eventHandler?(.componentOpened(attempt, component, locationPath))
        case .parentAnchored:
            eventHandler?(.parentAnchored(attempt, locationPath))
        case .fileOpened:
            eventHandler?(.fileOpened(attempt, locationPath))
        case .temporaryFileCreated,
             .temporaryFilePrepared,
             .willCommit,
             .didCommit,
             .displacedEntryCaptured,
             .willRollback,
             .didRollback,
             .namespaceValidated:
            break
        case let .readChunk(chunk):
            eventHandler?(.readChunk(attempt, chunk, locationPath))
        case .bytesRead:
            break
        case .postflight:
            eventHandler?(.postflight(attempt, locationPath))
        }
    }

    private static func searchError(from error: Error) -> Error {
        guard let error = error as? WorkspaceAnchoredFileSystemError else {
            return error
        }
        return switch error {
        case .missing: WorkspaceSearchFileReadError.disappeared
        case .symbolicLink: WorkspaceSearchFileReadError.symbolicLink
        case .notRegularFile: WorkspaceSearchFileReadError.notRegularFile
        case .unreadable,
             .changedIdentity,
             .changedContent,
             .namespaceChanged,
             .unstable,
             .durabilityFailed,
             .cleanupFailed:
            WorkspaceSearchFileReadError.unreadable
        case .cancelled: CancellationError()
        }
    }
}
