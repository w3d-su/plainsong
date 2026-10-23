import SwiftUI
import UIKit

/// UIKit container that keeps the scene's single editor view and single
/// preview view permanently mounted. `mode` changes only geometry and
/// `isHidden` — the hosted views never leave the hierarchy, so selection,
/// scroll position, marked text and the Undo stack cannot be lost to a
/// layout transition. Hidden panes are also unreachable to VoiceOver
/// (`isHidden` removes them from the accessibility tree).
///
/// Kept in plain UIKit (not a SwiftView branch) so that toggling between
/// single/side-by-side is a property change on one stable view, not a
/// view-tree reconstruction.
final class IOSDualPaneContainerView: UIView {
    enum Mode: Equatable {
        case single(IOSEditorPane)
        case sideBySide
    }

    private(set) var mode: Mode = .single(.source)
    private(set) var editorView: UIView?
    private(set) var previewView: UIView?
    private let separator = UIView()

    /// Editor width fraction in side-by-side mode. Fixed for v1 — an
    /// adjustable divider is a later enhancement, not a gate.
    var editorFraction: CGFloat = 0.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        separator.backgroundColor = .separator
        separator.isHidden = true
        addSubview(separator)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    /// Replaces hosted panes only on a genuine instance change (document
    /// attach retarget or provider swap), never on a layout change.
    func setPanes(editor: UIView?, preview: UIView?) {
        if editorView !== editor {
            editorView?.removeFromSuperview()
            editorView = editor
            if let editor {
                insertSubview(editor, belowSubview: separator)
            }
        }
        if previewView !== preview {
            previewView?.removeFromSuperview()
            previewView = preview
            if let preview {
                insertSubview(preview, belowSubview: separator)
            }
        }
        // Newly attached panes inherit the current mode's visibility — a pane
        // installed while hidden must not appear before the next layout pass.
        updateVisibility()
        setNeedsLayout()
    }

    func apply(mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        // Apply visibility immediately (not just at layoutSubviews) so the
        // accessibility tree flips deterministically in the same run-loop pass.
        updateVisibility()
        setNeedsLayout()
    }

    private func updateVisibility() {
        switch mode {
        case let .single(pane):
            editorView?.isHidden = pane != .source
            previewView?.isHidden = pane != .preview
            separator.isHidden = true
        case .sideBySide:
            editorView?.isHidden = false
            previewView?.isHidden = false
            separator.isHidden = editorView == nil || previewView == nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        switch mode {
        case let .single(pane):
            switch pane {
            case .source:
                editorView?.frame = bounds
            case .preview:
                previewView?.frame = bounds
            }
            separator.frame = .zero
        case .sideBySide:
            let dividerWidth = 1.0 / max(traitCollection.displayScale, 1)
            let editorWidth = (bounds.width - dividerWidth) * editorFraction
            editorView?.frame = CGRect(x: 0, y: 0, width: editorWidth, height: bounds.height)
            previewView?.frame = CGRect(
                x: editorWidth + dividerWidth, y: 0,
                width: bounds.width - editorWidth - dividerWidth, height: bounds.height
            )
            separator.frame = CGRect(x: editorWidth, y: 0, width: dividerWidth, height: bounds.height)
        }
    }
}

/// SwiftUI bridge for the dual-pane container. `layout` flows through
/// `updateUIView` only; the hosted `UIView`s come from the scene's retained
/// cache so even a wholesale representable re-creation re-attaches the same
/// instances rather than building new ones.
struct IOSEditorPreviewContainer: UIViewRepresentable {
    let layout: IOSContentLayout
    let editorView: UIView?
    let previewView: UIView?

    func makeUIView(context _: Context) -> IOSDualPaneContainerView {
        let container = IOSDualPaneContainerView()
        container.setPanes(editor: editorView, preview: previewView)
        container.apply(mode: layout.containerMode)
        return container
    }

    func updateUIView(_ container: IOSDualPaneContainerView, context _: Context) {
        container.setPanes(editor: editorView, preview: previewView)
        container.apply(mode: layout.containerMode)
    }
}

extension IOSContentLayout {
    var containerMode: IOSDualPaneContainerView.Mode {
        switch self {
        case let .single(pane): .single(pane)
        case .sideBySide: .sideBySide
        }
    }
}
