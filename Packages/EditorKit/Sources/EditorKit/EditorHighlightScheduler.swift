import Combine
import MarkdownCore

@MainActor
final class EditorHighlightScheduler: ObservableObject {
    typealias Debounce = HighlightScheduler.Debounce
    private let scheduler: HighlightScheduler

    init(debounce: @escaping Debounce = { await MarkdownEditorView.waitForHighlightDebounce() }) {
        scheduler = HighlightScheduler(debounce: debounce)
    }

    func restart(revision: Int, apply: @escaping @MainActor (Int) async -> Void) {
        scheduler.restart { _ in await apply(revision) }
    }

    func activate() {
        scheduler.activate()
    }

    func cancel() {
        scheduler.cancel()
    }
}
