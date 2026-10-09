import SwiftUI

/// Hosts the existing UITextView. Parents hide this view in place; a SwiftUI `if`
/// removes the native view and its undo stack, selection, and marked text.
public struct IOSMarkdownEditorRepresentable: UIViewRepresentable {
    public let controller: IOSSourceEditorController

    public init(controller: IOSSourceEditorController) {
        self.controller = controller
    }

    public func makeUIView(context _: Context) -> IOSMarkdownTextView {
        controller.textView
    }

    public func updateUIView(_: IOSMarkdownTextView, context _: Context) {
        controller.acceptInterfaceUpdate()
    }

    public static func dismantleUIView(_ textView: IOSMarkdownTextView, coordinator _: Coordinator) {
        textView.editor?.invalidateHost()
    }
}
