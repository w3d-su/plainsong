import Foundation
import MarkdownCore

@MainActor
final class IOSDocumentStoreObservation: IOSObservation {
    let token = UUID()
    var handler: (@MainActor (IOSDocumentEvent) -> Void)?

    init(handler: @escaping @MainActor (IOSDocumentEvent) -> Void) {
        self.handler = handler
    }

    func cancel() {
        handler = nil
    }
}
