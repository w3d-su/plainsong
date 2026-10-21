import Foundation

/// Opaque authority copied from 06 by 13; no WorkspaceKitIOS dependency in PreviewKit.
public struct PreviewAssetAccessContext: Sendable {
    public let allowedRoot: URL
    public let rootToken: UUID
    public let grantIdentity: UUID
    public let accessGeneration: UInt64

    public init(allowedRoot: URL, rootToken: UUID, grantIdentity: UUID, accessGeneration: UInt64) {
        self.allowedRoot = allowedRoot
        self.rootToken = rootToken
        self.grantIdentity = grantIdentity
        self.accessGeneration = accessGeneration
    }
}

public struct PreviewAssetReadRequest: Sendable {
    public let requestID: UUID
    public let resolvedURL: URL
    public let access: PreviewAssetAccessContext
    public let maximumByteCount: Int

    public init(requestID: UUID, resolvedURL: URL, access: PreviewAssetAccessContext, maximumByteCount: Int) {
        self.requestID = requestID
        self.resolvedURL = resolvedURL
        self.access = access
        self.maximumByteCount = maximumByteCount
    }
}

public struct PreviewAssetReadResult: Sendable {
    public let requestID: UUID
    public let coordinatedURL: URL
    public let bytes: Data
    public let access: PreviewAssetAccessContext

    public init(requestID: UUID, coordinatedURL: URL, bytes: Data, access: PreviewAssetAccessContext) {
        self.requestID = requestID
        self.coordinatedURL = coordinatedURL
        self.bytes = bytes
        self.access = access
    }
}

public enum PreviewAssetReadFailure: Error, Equatable, Sendable {
    case unavailable
    case accessChanged
    case outsideRoot
    case unsupportedType
    case tooLarge
    case providerFailed
}

/// 06 holds a lease through the read and returns the actual coordinated location.
/// Throws PreviewAssetReadFailure or CancellationError, never empty bytes as failure.
public protocol PreviewAssetReading: Sendable {
    func read(_ request: PreviewAssetReadRequest) async throws -> PreviewAssetReadResult
}

/// 07 synchronously checks before every WebKit callback, including didFinish.
/// MainActor serializes root switches/revocation against this final check and send.
@MainActor
public protocol PreviewAssetAccessChecking: AnyObject {
    func isCurrent(_ context: PreviewAssetAccessContext) -> Bool
}
