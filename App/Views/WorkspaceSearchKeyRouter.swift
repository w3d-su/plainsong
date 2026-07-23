import AppKit
import SwiftUI

/// Concrete results responder used when SwiftUI logical focus cannot prove AppKit key delivery.
@MainActor
final class WorkspaceSearchKeyRouterController: ObservableObject {
    fileprivate weak var view: WorkspaceSearchKeyRouterView?

    var isFirstResponder: Bool {
        guard let view else { return false }
        return view.window?.firstResponder === view
    }

    func requestFocus() -> Bool {
        guard let view, let window = view.window else { return false }
        return window.makeFirstResponder(view) && window.firstResponder === view
    }
}

enum WorkspaceSearchResultsKeyCommand {
    case moveUp
    case moveDown
    case activate
    case escape
}

struct WorkspaceSearchResultsKeyRouterReader: NSViewRepresentable {
    @ObservedObject var controller: WorkspaceSearchKeyRouterController
    let onCommand: (WorkspaceSearchResultsKeyCommand) -> Void
    let onFocusTraversal: () -> Void

    func makeNSView(context _: Context) -> WorkspaceSearchKeyRouterView {
        let view = WorkspaceSearchKeyRouterView()
        view.onCommand = onCommand
        view.onFocusTraversal = onFocusTraversal
        controller.view = view
        return view
    }

    func updateNSView(_ view: WorkspaceSearchKeyRouterView, context _: Context) {
        view.onCommand = onCommand
        view.onFocusTraversal = onFocusTraversal
        controller.view = view
    }
}

final class WorkspaceSearchKeyRouterView: NSView {
    var onCommand: ((WorkspaceSearchResultsKeyCommand) -> Void)?
    var onFocusTraversal: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func moveUp(_: Any?) {
        onCommand?(.moveUp)
    }

    override func moveDown(_: Any?) {
        onCommand?(.moveDown)
    }

    override func insertNewline(_: Any?) {
        onCommand?(.activate)
    }

    override func insertTab(_: Any?) {
        onFocusTraversal?()
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_: Any?) {
        onFocusTraversal?()
        window?.selectPreviousKeyView(self)
    }

    override func cancelOperation(_: Any?) {
        onCommand?(.escape)
    }
}
