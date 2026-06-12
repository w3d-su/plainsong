import Foundation

/// MarkdownCore is the pure-logic layer of BlogEditor (agent.md §4):
/// document model, completion engine, table formatter, scroll-sync mapping.
/// **This package must never import AppKit, SwiftUI, or WebKit.**
public enum MarkdownCoreInfo {
    public static let version = "0.1.0"
}

/// The kind of file a document session edits. Drives editor grammar selection
/// and the preview pipeline variant (agent.md §6.2, §7.2).
public enum FileKind: String, CaseIterable, Codable, Sendable {
    case markdown
    case mdx

    /// Recognized file extensions, lowercased.
    public static let markdownExtensions: Set<String> = ["md", "markdown"]
    public static let mdxExtensions: Set<String> = ["mdx"]

    public init?(fileExtension: String) {
        let ext = fileExtension.lowercased()
        if Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if Self.mdxExtensions.contains(ext) {
            self = .mdx
        } else {
            return nil
        }
    }

    public init?(url: URL) {
        self.init(fileExtension: url.pathExtension)
    }
}
