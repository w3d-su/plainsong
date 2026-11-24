import Foundation
import MarkdownCore

@MainActor
final class IOSDocumentStoreObservation: IOSObservation {
    let token = UUID()
    var handler: (@MainActor (IOSDocumentEvent) -> Void)?
    /// Removes this observation from its owner, so a cancelled subscriber is not retained.
    var onCancel: (@MainActor () -> Void)?

    init(handler: @escaping @MainActor (IOSDocumentEvent) -> Void) {
        self.handler = handler
    }

    func cancel() {
        handler = nil
        onCancel?()
        onCancel = nil
    }
}
