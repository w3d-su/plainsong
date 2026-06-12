import EditorKit
import PreviewKit
import SwiftUI

@MainActor
final class EditorPreviewScrollCoordinator: ObservableObject {
    let editorProxy = EditorScrollProxy()

    private weak var previewController: PreviewController?
    private var scrollOwner: ScrollOwner = .none
    private var decayTask: Task<Void, Never>?
    private var isEditorScrollForwardingEnabled = false

    init() {
        editorProxy.onVisibleLineChanged = { [weak self] line in
            self?.editorScrolledFromProxy(to: line)
        }
    }

    func connect(previewController: PreviewController) {
        self.previewController = previewController
    }

    func setEditorScrollForwardingEnabled(_ isEnabled: Bool) {
        isEditorScrollForwardingEnabled = isEnabled
    }

    func previewScrolled(to line: Int) {
        guard scrollOwner != .editor else { return }

        setScrollOwner(.preview)
        editorProxy.scrollToLine(line)
    }

    private func editorScrolledFromProxy(to line: Int) {
        guard isEditorScrollForwardingEnabled, scrollOwner != .preview else { return }

        setScrollOwner(.editor)
        previewController?.scrollToLine(line, animated: false)
    }

    private func setScrollOwner(_ owner: ScrollOwner) {
        scrollOwner = owner
        decayTask?.cancel()
        decayTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            self?.scrollOwner = .none
        }
    }

    private enum ScrollOwner {
        case editor
        case preview
        case none
    }
}
