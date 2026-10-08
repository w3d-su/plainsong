import Foundation
import MarkdownCore

public struct IOSWorkspaceIdentity: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Provider-supplied opaque bytes scoped to a workspace; never a Darwin inode proof.
public struct IOSWorkspaceResourceIdentity: Hashable, Codable, Sendable {
    public let rawValue: Data

    public init(rawValue: Data) {
        self.rawValue = rawValue
    }
}

/// A descriptor, not a grant. Consumers must use the matching provider and lease.
/// Preserve relativePath spelling. Do not use String/URL equality as authority.
public struct IOSFileLocation: Sendable {
    public let workspaceID: IOSWorkspaceIdentity
    public let accessGeneration: UInt64
    public let relativePath: String
    public let fileURL: URL
    public let resourceID: IOSWorkspaceResourceIdentity?

    public init(
        workspaceID: IOSWorkspaceIdentity,
        accessGeneration: UInt64,
        relativePath: String,
        fileURL: URL,
        resourceID: IOSWorkspaceResourceIdentity?
    ) {
        self.workspaceID = workspaceID
        self.accessGeneration = accessGeneration
        self.relativePath = relativePath
        self.fileURL = fileURL
        self.resourceID = resourceID
    }
}

public enum IOSFileAvailability: Equatable, Sendable {
    case available(canWrite: Bool)
    case downloading
    case offline
    case unavailable
    case removed
}

public struct IOSWorkspaceEntry: Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case directory
        case document(FileKind)
        case image
        case other
    }

    /// Display identity only. It does not authorize a file operation.
    public let id: UUID
    public let location: IOSFileLocation
    public let kind: Kind
    public let availability: IOSFileAvailability
    public let children: [IOSWorkspaceEntry]

    public init(
        id: UUID,
        location: IOSFileLocation,
        kind: Kind,
        availability: IOSFileAvailability,
        children: [IOSWorkspaceEntry]
    ) {
        self.id = id
        self.location = location
        self.kind = kind
        self.availability = availability
        self.children = children
    }
}

public struct IOSWorkspaceSnapshot: Sendable {
    public let workspaceID: IOSWorkspaceIdentity
    public let accessGeneration: UInt64
    public let requestID: UUID
    public let entries: [IOSWorkspaceEntry]

    public init(
        workspaceID: IOSWorkspaceIdentity,
        accessGeneration: UInt64,
        requestID: UUID,
        entries: [IOSWorkspaceEntry]
    ) {
        self.workspaceID = workspaceID
        self.accessGeneration = accessGeneration
        self.requestID = requestID
        self.entries = entries
    }
}
