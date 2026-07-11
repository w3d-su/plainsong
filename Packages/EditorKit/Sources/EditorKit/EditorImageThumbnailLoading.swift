import Foundation
import MarkdownCore

/// Downsampled image data crossing the EditorKit loader seam.
///
/// EditorKit deliberately owns this value so it never imports WorkspaceKit. The later
/// enablement PR can adapt `WorkspaceImageThumbnailProvider` into this shape.
public struct EditorImageThumbnail: Sendable, Equatable {
    public let pngData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let resolvedWorkspaceRelativePath: String
    public let contentModificationDate: Date

    public init(
        pngData: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        resolvedWorkspaceRelativePath: String,
        contentModificationDate: Date
    ) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.resolvedWorkspaceRelativePath = resolvedWorkspaceRelativePath
        self.contentModificationDate = contentModificationDate
    }
}

public enum EditorImageThumbnailFailure: Error, Sendable, Equatable {
    case missingFile
    case unreadableFile
    case decodeFailed
    case emptyImage
}

public enum EditorImageThumbnailOutcome: Sendable, Equatable {
    case ready(EditorImageThumbnail)
    case stayRaw(MarkdownImageStayRawReason)
    case failed(EditorImageThumbnailFailure)
}

/// EditorKit-side loader seam mirroring WorkspaceKit's thumbnail request contract.
public protocol EditorImageThumbnailLoading: AnyObject, Sendable {
    func loadThumbnail(
        rootURL: URL,
        documentDirectoryRelativePath: String,
        source: String,
        maxPixelSize: Int
    ) async -> EditorImageThumbnailOutcome
}

/// Internal-hook configuration. Supplying this value alone never enables presentation;
/// the existing WYSIWYG development presentation must also be active.
public struct EditorImageThumbnailConfiguration {
    public static let defaultMaximumPixelSize = 600

    public let loader: any EditorImageThumbnailLoading
    public let rootURL: URL
    public let documentDirectoryRelativePath: String
    public let maximumPixelSize: Int
    public let refreshProxy: EditorImageThumbnailRefreshProxy?

    public init(
        loader: any EditorImageThumbnailLoading,
        rootURL: URL,
        documentDirectoryRelativePath: String,
        maximumPixelSize: Int = Self.defaultMaximumPixelSize,
        refreshProxy: EditorImageThumbnailRefreshProxy? = nil
    ) {
        precondition(maximumPixelSize > 0, "Thumbnail pixel size must be positive")
        self.loader = loader
        self.rootURL = rootURL
        self.documentDirectoryRelativePath = documentDirectoryRelativePath
        self.maximumPixelSize = maximumPixelSize
        self.refreshProxy = refreshProxy
    }
}

/// App-facing refresh entry point for a later FSEvents adapter.
///
/// One proxy may fan out to multiple editor instances. Calls are main-actor isolated so
/// marker replacement, selection preservation, and TextKit invalidation remain ordered.
@MainActor
public final class EditorImageThumbnailRefreshProxy {
    private var handlers: [UUID: (Set<String>) -> Void] = [:]

    public init() {}

    public func invalidateThumbnails(forWorkspaceRelativePaths paths: [String]) {
        let normalizedPaths = Set(paths.compactMap(Self.normalizedWorkspaceRelativePath))
        guard !normalizedPaths.isEmpty else {
            return
        }

        for handler in handlers.values {
            handler(normalizedPaths)
        }
    }

    func attach(id: UUID, handler: @escaping (Set<String>) -> Void) {
        handlers[id] = handler
    }

    func detach(id: UUID) {
        handlers[id] = nil
    }

    static func normalizedWorkspaceRelativePath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            return nil
        }

        let standardized = (trimmed as NSString).standardizingPath
        guard standardized != ".",
              standardized != "..",
              !standardized.hasPrefix("../")
        else {
            return nil
        }
        return standardized
    }
}
