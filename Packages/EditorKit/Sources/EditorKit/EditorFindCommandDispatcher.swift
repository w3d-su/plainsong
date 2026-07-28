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
/// Unlike the Format dispatcher this reports delivery, because App owns a real fallback: when
/// the find field rather than the editor holds focus there is no `STTextView` on the responder
/// path, and the command has to be applied against shared `AppState` instead.
@MainActor
public enum EditorFindCommandDispatcher {
    /// Returns `true` when a responder accepted the command.
    @discardableResult
    public static func send(_ command: EditorFindCommand) -> Bool {
        send(command, to: nil)
    }

    /// Delivery to an explicit target, for tests that cannot rely on a runner's key window.
    ///
    /// Uses `NSApplication.shared` rather than `NSApp`: the latter is `nil` until something
    /// has instantiated the application, which in a unit-test process depends on test order.
    @discardableResult
    static func send(_ command: EditorFindCommand, to target: AnyObject?) -> Bool {
        NSApplication.shared.sendAction(selector(for: command), to: target, from: nil)
    }

    private static func selector(for command: EditorFindCommand) -> Selector {
        switch command {
        case .show: #selector(STTextView.plainsongShowFind(_:))
        case .next: #selector(STTextView.plainsongFindNext(_:))
        case .previous: #selector(STTextView.plainsongFindPrevious(_:))
        case .useSelection: #selector(STTextView.plainsongUseSelectionForFind(_:))
        }
    }
}
