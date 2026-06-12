import Foundation

/// Renderable document state delivered on the preview-only text channel.
///
/// `DocumentSession.text` and `DocumentSession.version` intentionally stay out of
/// `@Published`; this value flows through an explicit subscription so preview updates
/// never cause whole-window SwiftUI invalidation on every keystroke.
public struct DocumentTextChange: Sendable, Equatable {
    public let text: String
    public let version: Int
    public let fileKind: FileKind
    public let fileURL: URL?

    public init(text: String, version: Int, fileKind: FileKind, fileURL: URL?) {
        self.text = text
        self.version = version
        self.fileKind = fileKind
        self.fileURL = fileURL
    }
}
