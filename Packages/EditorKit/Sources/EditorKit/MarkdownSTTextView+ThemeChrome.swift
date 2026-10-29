import AppKit
import STTextView

/// Holds a custom selection color against `STSelectionHighlightView`, which
/// otherwise writes the system selection color into its layer on appearance
/// and key-window changes.
final class EditorSelectionTintLayer: CALayer {
    var enforcedColor: CGColor? {
        didSet {
            super.backgroundColor = enforcedColor ?? super.backgroundColor
        }
    }

    override var backgroundColor: CGColor? {
        get { super.backgroundColor }
        set {
            super.backgroundColor = enforcedColor ?? newValue
        }
    }
}

extension MarkdownSTTextView {
    func refreshEditorSelectionColor() {
        guard let editorSelectionColor, editorSelectionColor != .selectedTextBackgroundColor else {
            selectionColorRefresh?.cancel()
            removeEditorSelectionColorObserver()
            releaseCustomSelectionTint(in: self)
            enforcesCustomSelectionColor = false
            return
        }
        installEditorSelectionColorObserverIfNeeded()
        paintEditorSelectionColor(editorSelectionColor)
        enforcesCustomSelectionColor = true
        selectionColorRefresh?.cancel()
        let color = editorSelectionColor
        selectionColorRefresh = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.editorSelectionColor == color else { return }
            paintEditorSelectionColor(color)
        }
    }

    /// STTextView rebuilds selection overlays with the system color. Repaint those views only.
    func paintEditorSelectionColor(_ color: NSColor) {
        guard color != .selectedTextBackgroundColor else { return }
        paintEditorSelectionColor(color, in: self)
    }

    func releaseCustomSelectionTint(in view: NSView) {
        if let tint = view.layer as? EditorSelectionTintLayer {
            tint.enforcedColor = nil
            let system = view.window?.isKeyWindow == true
                ? NSColor.selectedTextBackgroundColor
                : NSColor.unemphasizedSelectedTextBackgroundColor
            tint.backgroundColor = system.cgColor
        }
        for subview in view.subviews {
            releaseCustomSelectionTint(in: subview)
        }
    }

    func removeEditorSelectionColorObserver() {
        guard let editorSelectionColorObserver else { return }
        NotificationCenter.default.removeObserver(editorSelectionColorObserver)
        self.editorSelectionColorObserver = nil
        observesEditorSelectionColor = false
    }

    private func installEditorSelectionColorObserverIfNeeded() {
        guard !observesEditorSelectionColor else { return }
        observesEditorSelectionColor = true
        let observer = NotificationCenter.default.addObserver(
            forName: STTextView.didChangeSelectionNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.selectedRange().length > 0 else { return }
                self.refreshEditorSelectionColor()
            }
        }
        editorSelectionColorObserver = observer
    }

    private func paintEditorSelectionColor(_ color: NSColor, in view: NSView) {
        if String(describing: type(of: view)) == "STSelectionHighlightView" {
            enforceSelectionColor(color, on: view)
        }
        for subview in view.subviews {
            paintEditorSelectionColor(color, in: subview)
        }
    }

    private func enforceSelectionColor(_ color: NSColor, on view: NSView) {
        view.wantsLayer = true
        let tint: EditorSelectionTintLayer
        if let existing = view.layer as? EditorSelectionTintLayer {
            tint = existing
        } else {
            tint = EditorSelectionTintLayer()
            tint.contentsScale = view.window?.backingScaleFactor ?? view.layer?.contentsScale ?? 2
            view.layer = tint
        }
        tint.enforcedColor = resolvedSelectionCGColor(color, in: view)
    }

    private func resolvedSelectionCGColor(_ color: NSColor, in view: NSView) -> CGColor {
        var resolved = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}
