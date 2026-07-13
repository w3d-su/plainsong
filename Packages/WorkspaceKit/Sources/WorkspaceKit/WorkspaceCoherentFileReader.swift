import CryptoKit
import Darwin
import Foundation

/// Stable physical identity obtained without following the final path component.
public struct WorkspaceFileSystemIdentity: Sendable, Hashable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// High-resolution metadata sampled from one open file descriptor.
public struct WorkspaceCoherentFileMetadata: Sendable, Equatable {
    public let identity: WorkspaceFileSystemIdentity
    public let byteCount: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64

    public init(
        identity: WorkspaceFileSystemIdentity,
        byteCount: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        changeSeconds: Int64,
        changeNanoseconds: Int64
    ) {
        self.identity = identity
        self.byteCount = byteCount
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }
}

public struct WorkspaceCoherentFileSnapshot: Sendable, Equatable {
    public let text: String
    public let exactBytes: Data
    public let sha256Digest: String
    public let metadata: WorkspaceCoherentFileMetadata

    public init(
        text: String,
        exactBytes: Data,
        sha256Digest: String,
        metadata: WorkspaceCoherentFileMetadata
    ) {
        self.text = text
        self.exactBytes = exactBytes
        self.sha256Digest = sha256Digest
        self.metadata = metadata
    }
}

public enum WorkspaceCoherentFileReadOutcome: Sendable, Equatable {
    case loaded(WorkspaceCoherentFileSnapshot)
    case missing
    case symbolicLink
    case notRegularFile
    case unreadable
    case invalidUTF8
    case namespaceChanged
    case unstable
    case cancelled
}

public protocol WorkspaceCoherentFileReading: Sendable {
    func readCoherentFile(at url: URL) async -> WorkspaceCoherentFileReadOutcome
    func readCoherentFile(at location: WorkspaceFileSystemLocation) async -> WorkspaceCoherentFileReadOutcome
}

public extension WorkspaceCoherentFileReading {
    func readCoherentFile(at location: WorkspaceFileSystemLocation) async -> WorkspaceCoherentFileReadOutcome {
        await readCoherentFile(at: location.fileURL)
    }
}

/// Reads one literal path from one stable descriptor while one security-scoped lease
/// covers every preflight, open, retry, and byte read.
public struct WorkspaceCoherentFileReader: WorkspaceCoherentFileReading, Sendable {
    let retryLimit: Int
    let eventHandler: (@Sendable (Event) -> Void)?

    public init(retryLimit: Int = 3) {
        self.retryLimit = max(1, retryLimit)
        eventHandler = nil
    }

    init(
        retryLimit: Int = 3,
        eventHandler: @escaping @Sendable (Event) -> Void
    ) {
        self.retryLimit = max(1, retryLimit)
        self.eventHandler = eventHandler
    }

    public func readCoherentFile(at url: URL) async -> WorkspaceCoherentFileReadOutcome {
        guard let location = try? WorkspaceFileSystemLocation(fileURL: url) else {
            return .unreadable
        }
        return await readCoherentFile(at: location)
    }

    public func readCoherentFile(
        at location: WorkspaceFileSystemLocation
    ) async -> WorkspaceCoherentFileReadOutcome {
        let readOutcome = WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
            eventHandler?(.accessBegan)
            defer { eventHandler?(.accessEnded) }

            for attempt in 0 ..< retryLimit {
                guard !Task.isCancelled else {
                    eventHandler?(.cancelled)
                    return ReadAttemptOutcome.failure(.cancelled)
                }
                eventHandler?(.preflight(attempt))
                guard !Task.isCancelled else {
                    eventHandler?(.cancelled)
                    return ReadAttemptOutcome.failure(.cancelled)
                }
                let outcome = readAttempt(at: location, attempt: attempt)
                switch outcome {
                case .failure(.unstable) where attempt + 1 < retryLimit:
                    guard !Task.isCancelled else {
                        eventHandler?(.cancelled)
                        return ReadAttemptOutcome.failure(.cancelled)
                    }
                    eventHandler?(.retry(attempt))
                    continue
                default:
                    return outcome
                }
            }
            return ReadAttemptOutcome.failure(.unstable)
        }

        switch readOutcome {
        case let .success(result):
            return prepareSnapshot(from: result)
        case let .failure(outcome):
            return outcome
        }
    }
}

extension WorkspaceCoherentFileReader {
    enum Event: Equatable {
        case accessBegan
        case preflight(Int)
        case rootAnchored(Int)
        case componentOpened(Int, String)
        case parentAnchored(Int)
        case opened(Int)
        case readChunk(Int, Int)
        case bytesRead(Int)
        case postflight(Int)
        case digestChunk(Int)
        case retry(Int)
        case cancelled
        case accessEnded
    }

    private enum ReadAttemptOutcome {
        case success(WorkspaceAnchoredFileSystem.ReadResult)
        case failure(WorkspaceCoherentFileReadOutcome)
    }

    private func readAttempt(
        at location: WorkspaceFileSystemLocation,
        attempt: Int
    ) -> ReadAttemptOutcome {
        do {
            let result = try WorkspaceAnchoredFileSystem.read(
                location,
                maximumByteCount: nil,
                hooks: .init(eventHandler: { event in
                    switch event {
                    case .rootAnchored:
                        eventHandler?(.rootAnchored(attempt))
                    case let .componentOpened(component):
                        eventHandler?(.componentOpened(attempt, component))
                    case .parentAnchored:
                        eventHandler?(.parentAnchored(attempt))
                    case .fileOpened:
                        eventHandler?(.opened(attempt))
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
                        eventHandler?(.readChunk(attempt, chunk))
                    case .bytesRead:
                        eventHandler?(.bytesRead(attempt))
                    case .postflight:
                        eventHandler?(.postflight(attempt))
                    }
                })
            )
            return .success(result)
        } catch let error as WorkspaceAnchoredFileSystemError {
            let failure: WorkspaceCoherentFileReadOutcome = switch error {
            case .missing: .missing
            case .symbolicLink: .symbolicLink
            case .notRegularFile: .notRegularFile
            case .unreadable: .unreadable
            case .changedIdentity, .namespaceChanged:
                .namespaceChanged
            case .changedContent, .unstable:
                .unstable
            case .durabilityFailed, .cleanupFailed:
                .unreadable
            case .cancelled:
                {
                    eventHandler?(.cancelled)
                    return .cancelled
                }()
            }
            return .failure(failure)
        } catch {
            return .failure(.unreadable)
        }
    }

    private func prepareSnapshot(
        from result: WorkspaceAnchoredFileSystem.ReadResult
    ) -> WorkspaceCoherentFileReadOutcome {
        guard !Task.isCancelled else {
            eventHandler?(.cancelled)
            return .cancelled
        }
        guard let text = String(data: result.data, encoding: .utf8) else {
            return .invalidUTF8
        }
        guard !Task.isCancelled else {
            eventHandler?(.cancelled)
            return .cancelled
        }

        var hasher = SHA256()
        let chunkByteCount = 64 * 1024
        var offset = 0
        var chunkIndex = 0
        while offset < result.data.count {
            guard !Task.isCancelled else {
                eventHandler?(.cancelled)
                return .cancelled
            }
            let upperBound = min(offset + chunkByteCount, result.data.count)
            hasher.update(data: result.data[offset ..< upperBound])
            eventHandler?(.digestChunk(chunkIndex))
            offset = upperBound
            chunkIndex += 1
        }
        guard !Task.isCancelled else {
            eventHandler?(.cancelled)
            return .cancelled
        }

        let digest = hasher.finalize().map { byte in
            String(format: "%02x", byte)
        }.joined()
        return .loaded(WorkspaceCoherentFileSnapshot(
            text: text,
            exactBytes: result.data,
            sha256Digest: digest,
            metadata: result.metadata
        ))
    }

    static func metadata(from fileStatus: stat) -> WorkspaceCoherentFileMetadata {
        WorkspaceCoherentFileMetadata(
            identity: WorkspaceFileSystemIdentity(
                device: UInt64(fileStatus.st_dev),
                inode: UInt64(fileStatus.st_ino)
            ),
            byteCount: Int64(fileStatus.st_size),
            modificationSeconds: Int64(fileStatus.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(fileStatus.st_mtimespec.tv_nsec),
            changeSeconds: Int64(fileStatus.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(fileStatus.st_ctimespec.tv_nsec)
        )
    }

    static func isRegularFile(_ fileStatus: stat) -> Bool {
        (fileStatus.st_mode & S_IFMT) == S_IFREG
    }
}

public enum WorkspaceNoFollowFileStatus: Sendable, Equatable {
    case regular(WorkspaceFileSystemIdentity)
    case missing
    case symbolicLink
    case notRegularFile
    case unreadable
}

public enum WorkspaceNoFollowFileInspector {
    public static func status(at url: URL) -> WorkspaceNoFollowFileStatus {
        guard let location = try? WorkspaceFileSystemLocation(fileURL: url) else {
            return .unreadable
        }
        return status(at: location)
    }

    public static func status(
        at location: WorkspaceFileSystemLocation
    ) -> WorkspaceNoFollowFileStatus {
        do {
            let metadata = try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
                try WorkspaceAnchoredFileSystem.validate(location)
            }
            return .regular(metadata.identity)
        } catch let error as WorkspaceAnchoredFileSystemError {
            return switch error {
            case .missing: .missing
            case .symbolicLink: .symbolicLink
            case .notRegularFile: .notRegularFile
            case .unreadable,
                 .changedIdentity,
                 .changedContent,
                 .namespaceChanged,
                 .unstable,
                 .durabilityFailed,
                 .cleanupFailed,
                 .cancelled:
                .unreadable
            }
        } catch {
            return .unreadable
        }
    }
}
