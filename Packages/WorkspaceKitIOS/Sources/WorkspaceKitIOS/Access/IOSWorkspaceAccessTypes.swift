import Foundation
import WorkspaceCore

enum IOSAccessProvenance: Sendable {
    case userSelection
    case bookmarkRestore
    case appContainer
}

enum IOSScopeAdmission: Equatable, Sendable {
    /// `startAccessingSecurityScopedResource()` returned true. One stop is required.
    case started
    /// The URL is already reachable. A false start is not success and does not need a stop.
    case reachableWithoutNewScope
    case denied
}

struct IOSBookmarkResolution: Sendable {
    var url: URL?
    var isStale: Bool
    var failure: IOSWorkspaceFailure?

    static func resolved(_ url: URL, isStale: Bool) -> IOSBookmarkResolution {
        IOSBookmarkResolution(url: url, isStale: isStale, failure: nil)
    }
}

struct IOSWorkspaceFileItem: Sendable {
    var relativePath: String
    var url: URL
    var isDirectory: Bool
    var isSymlink: Bool
    var fileSize: Int?
    var availability: IOSFileAvailability
    /// Nil means the provider did not supply a stable identity. Never an inode or URL.
    var providerIdentity: Data?
    var bytes: Data?
}

enum IOSExternalWorkspaceNotice: Sendable {
    case changed(relativePath: String)
    case deleted(relativePath: String)
    case moved(from: String, to: String)
    case availability(relativePath: String, IOSFileAvailability)
    case offlineRoot

    var coalesceKey: String {
        switch self {
        case let .changed(path), let .deleted(path), let .availability(path, _):
            path
        case let .moved(from, _):
            from
        case .offlineRoot:
            ""
        }
    }
}

public enum IOSRecentWorkspaceStatus: String, Codable, Sendable {
    case available
    case needsReselection
}

/// A recent successful open. Bookmark bytes stay in the store and are not on this value.
public struct IOSRecentWorkspaceItem: Equatable, Sendable {
    public let recordID: UUID
    public let displayName: String
    public let scope: IOSWorkspaceScope
    public let openedAt: Date
    public let providerIdentity: Data?
    public let status: IOSRecentWorkspaceStatus

    public init(
        recordID: UUID,
        displayName: String,
        scope: IOSWorkspaceScope,
        openedAt: Date,
        providerIdentity: Data?,
        status: IOSRecentWorkspaceStatus
    ) {
        self.recordID = recordID
        self.displayName = displayName
        self.scope = scope
        self.openedAt = openedAt
        self.providerIdentity = providerIdentity
        self.status = status
    }
}

struct IOSStoredRecentWorkspace: Codable, Equatable, Sendable {
    var recordID: UUID
    var displayName: String
    var scope: IOSWorkspaceScope
    var openedAt: Date
    var providerIdentity: Data?
    var status: IOSRecentWorkspaceStatus
    var bookmark: Data

    var item: IOSRecentWorkspaceItem {
        IOSRecentWorkspaceItem(
            recordID: recordID,
            displayName: displayName,
            scope: scope,
            openedAt: openedAt,
            providerIdentity: providerIdentity,
            status: status
        )
    }
}

struct IOSOperationTicket: Sendable {
    var workspaceID: IOSWorkspaceIdentity
    var generation: UInt64
    var rootToken: UUID
    var operationID: UUID
    var requestID: UUID?
}

struct IOSOwnedAssetRecord: Sendable {
    var operationID: UUID
    var ownershipToken: UUID
    var rootRelative: String
    var url: URL
    var providerIdentity: Data?
    var byteCount: Int
    var committed = false
    var removed = false
}

enum IOSWorkspaceFailureMapping {
    static func map(_ error: Error) -> IOSWorkspaceFailure {
        if let failure = error as? IOSWorkspaceFailure {
            return failure
        }
        if error is CancellationError {
            return .unavailable
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .notFound
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permissionDenied
            case NSFileWriteFileExistsError:
                return .alreadyExists
            case NSUserCancelledError:
                return .unavailable
            case NSUbiquitousFileUnavailableError,
                 NSUbiquitousFileNotUploadedDueToQuotaError,
                 NSUbiquitousFileUbiquityServerNotAvailable:
                return .offline
            default:
                if (NSUbiquitousFileErrorMinimum ... NSUbiquitousFileErrorMaximum).contains(nsError.code) {
                    return .offline
                }
            }
        }
        return .coordinationFailed
    }
}
