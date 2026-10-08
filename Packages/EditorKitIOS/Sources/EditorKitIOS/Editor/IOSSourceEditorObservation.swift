import Foundation
import MarkdownCore

@MainActor
final class IOSSourceEditorObservation: IOSObservation {
    private var handler: (@MainActor (IOSSourceEditorEvent) -> Void)?

    init(handler: @escaping @MainActor (IOSSourceEditorEvent) -> Void) {
        self.handler = handler
    }

    func cancel() {
        handler = nil
    }

    func emit(_ event: IOSSourceEditorEvent) {
        handler?(event)
    }
}
