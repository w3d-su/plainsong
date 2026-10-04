import Foundation
import MarkdownCore

/// Immutable document binding observed by in-document find.
public struct EditorFindDocumentBinding: Equatable, Sendable {
    public let identity: EditorDocumentIdentity?
    public let text: String
    public let revision: UInt64

    public init(identity: EditorDocumentIdentity?, text: String, revision: UInt64) {
        self.identity = identity
        self.text = text
        self.revision = revision
    }

    public static let empty = EditorFindDocumentBinding(identity: nil, text: "", revision: 0)
}
