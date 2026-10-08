import Foundation
import MarkdownCore

/// File kind used to filter and sort a workspace tree.
///
/// `image` is the authoring-tree classification (including SVG, HEIC, and TIFF).
/// It is wider than `MarkdownImageAssetPolicy`, which remains the preview raster allowlist.
public enum WorkspaceFileKind: Sendable, Equatable {
    case directory
    case markdown
    case mdx
    case image
    case other

    public init(url: URL, isDirectory: Bool) {
        if isDirectory {
            self = .directory
        } else if let fileKind = FileKind(url: url) {
            switch fileKind {
            case .markdown:
                self = .markdown
            case .mdx:
                self = .mdx
            }
        } else if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            self = .image
        } else {
            self = .other
        }
    }

    public var isEditableMarkdown: Bool {
        switch self {
        case .markdown, .mdx:
            true
        case .directory, .image, .other:
            false
        }
    }

    public var isVisibleByDefault: Bool {
        switch self {
        case .directory, .markdown, .mdx, .image:
            true
        case .other:
            false
        }
    }

    private static let imageExtensions: Set<String> = [
        "apng",
        "avif",
        "gif",
        "heic",
        "heif",
        "jpeg",
        "jpg",
        "png",
        "svg",
        "tif",
        "tiff",
        "webp",
    ]
}
