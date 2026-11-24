import AppKit
import STTextView

/// A find command App can send to the focused editor.
public enum EditorFindCommand: Equatable, Sendable {
    case show
    case next
    case previous
    case useSelection
}

/// Sends find commands down the AppKit responder chain.
///
/// Mirrors `EditorCommandDispatcher` for Format: the concrete editor type and its selectors
/// stay behind EditorKit, so App never names `STTextView` (agent.md §6.1 — "App/ and
/// MarkdownCore/ must never import STTextView types").
///
/// Unlike the Format dispatcher this reports delivery, because App owns a real fallback. The
/// find bar has focusable surfaces the responder chain cannot reach an editor through: the
/// owned query field and its field editor, and the bar's SwiftUI chrome (Aa, whole-word,
/// Previous, Next, Done). In all of those there is no `STTextView` on the responder path, so
/// App applies the command against shared `AppState` instead.
@MainActor
public enum EditorFindCommandDispatcher {
    /// Returns `true` when a responder accepted the command.
    @discardableResult
    public static func send(_ command: EditorFindCommand) -> Bool {
        // A nil-targeted action continues from the key window into the main window. With
        // Settings or another non-workspace window key, that reached the editor behind it.
        let application = NSApplication.shared
        let target = application.target(forAction: selector(for: command), to: nil, from: nil)
        guard let editor = target as? NSView,
              isDeliverable(toEditorIn: editor.window, keyWindow: EditorReplaceCommandDispatcher.keyWindow)
        else {
            return false
        }
        return send(command, to: editor)
    }

    /// An editor may take a find command only from its own window, or from a sheet or child
    /// window of it (those resolve to their workspace window, AGENT.md §4).
    static func isDeliverable(toEditorIn editorWindow: NSWindow?, keyWindow: NSWindow?) -> Bool {
        guard let editorWindow else {
            return false
        }
        var window = keyWindow
        var remaining = 16
        while let candidate = window, remaining > 0 {
            if candidate === editorWindow {
                return true
            }
            window = candidate.sheetParent ?? candidate.parent
            remaining -= 1
        }
        return false
    }

    /// Delivery to an explicit target, for tests that cannot rely on a runner's key window.
    ///
    /// Uses `NSApplication.shared` rather than `NSApp`: the latter is `nil` until something
    /// has instantiated the application, which in a unit-test process depends on test order.
    @discardableResult
    static func send(_ command: EditorFindCommand, to target: AnyObject?) -> Bool {
        NSApplication.shared.sendAction(selector(for: command), to: target, from: nil)
    }

    /// Internal so a test can ask `NSApplication.target(forAction:)` whether an editor is
    /// reachable, instead of inferring it from ambient responder state.
    static func selector(for command: EditorFindCommand) -> Selector {
        switch command {
        case .show: #selector(STTextView.plainsongShowFind(_:))
        case .next: #selector(STTextView.plainsongFindNext(_:))
        case .previous: #selector(STTextView.plainsongFindPrevious(_:))
        case .useSelection: #selector(STTextView.plainsongUseSelectionForFind(_:))
        }
    }
}
