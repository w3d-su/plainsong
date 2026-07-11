import Foundation

/// Opaque identity for one App-owned editor model binding.
///
/// This is deliberately separate from `EditorDocumentIdentity`: an optional document
/// identity describes navigation, while this value proves which exact model binding the
/// live EditorKit coordinator installed.
public struct EditorDocumentBindingID: Hashable, Sendable {
    private let rawValue: UUID

    public init() {
        rawValue = UUID()
    }
}

/// Installation lifecycle emitted by the live editor bridge.
public enum EditorDocumentBindingLifecycleEvent: Equatable, Sendable {
    case installed(EditorDocumentBindingID)
    case revoked(EditorDocumentBindingID)
}
