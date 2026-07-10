import CoreGraphics
import Foundation
import MarkdownCore

/// Downsampled thumbnail ready for a later presentation layer.
///
/// Pixel data is PNG-encoded so the value is `Sendable` and usable across App / EditorKit
/// protocol boundaries without importing WorkspaceKit or holding live `CGImage` references.
public struct WorkspaceImageThumbnail: Sendable, Equatable {
    /// PNG bytes of the downsampled bitmap (first GIF frame when the source is animated).
    public let pngData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let resolvedWorkspaceRelativePath: String
    public let contentModificationDate: Date
    public let sourceByteCount: Int64
    /// Approximate decoded cost used for LRU accounting (`pixelWidth * pixelHeight * 4`).
    public let decodedByteCost: Int

    public init(
        pngData: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        resolvedWorkspaceRelativePath: String,
        contentModificationDate: Date,
        sourceByteCount: Int64,
        decodedByteCost: Int
    ) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.resolvedWorkspaceRelativePath = resolvedWorkspaceRelativePath
        self.contentModificationDate = contentModificationDate
        self.sourceByteCount = sourceByteCount
        self.decodedByteCost = decodedByteCost
    }
}

public enum WorkspaceImageThumbnailFailure: Error, Equatable, Sendable {
    case missingFile
    case unreadableFile
    case decodeFailed
    case emptyImage
}

public enum WorkspaceImageThumbnailOutcome: Sendable, Equatable {
    case ready(WorkspaceImageThumbnail)
    case stayRaw(MarkdownImageStayRawReason)
    case failed(WorkspaceImageThumbnailFailure)
}

/// Observable cache counters for tests and later diagnostics.
public struct WorkspaceImageThumbnailCacheStats: Sendable, Equatable {
    public var hits: Int
    public var misses: Int
    public var evictions: Int
    public var entryCount: Int
    public var totalByteCost: Int
    public var coalescedLoads: Int

    public init(
        hits: Int = 0,
        misses: Int = 0,
        evictions: Int = 0,
        entryCount: Int = 0,
        totalByteCost: Int = 0,
        coalescedLoads: Int = 0
    ) {
        self.hits = hits
        self.misses = misses
        self.evictions = evictions
        self.entryCount = entryCount
        self.totalByteCost = totalByteCost
        self.coalescedLoads = coalescedLoads
    }
}

/// App-facing protocol so EditorKit can consume thumbnails without importing WorkspaceKit.
public protocol WorkspaceImageThumbnailLoading: Sendable {
    func loadThumbnail(
        rootURL: URL,
        documentDirectoryRelativePath: String,
        source: String,
        maxPixelSize: Int
    ) async -> WorkspaceImageThumbnailOutcome
}
