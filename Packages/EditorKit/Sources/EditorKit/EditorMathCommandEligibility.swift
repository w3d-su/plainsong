import AppKit
import Combine
import MarkdownCore
import STTextView

/// Publishes whether the Format menu's math insertion commands can apply in the
/// editor that currently owns first responder.
///
/// Coordinators report first-responder transitions (`activate`/`deactivate`)
/// and push computed availability via `publish(_:for:)` — published only while
/// that editor stays focused, so background editors cannot steal the menu
/// state. The scan itself is too expensive for the keystroke path on large
/// documents, so producers compute off the main actor and this store never
/// blocks the UI.
///
/// This drives menu *enablement only*. Command execution still dispatches
/// through the responder chain and re-validates the selection with the same
/// MarkdownCore predicates, so a stale flag can never cause a mutation.
@MainActor
public final class EditorMathCommandEligibility: ObservableObject {
    public static let shared = EditorMathCommandEligibility()

    @Published public private(set) var availability = MarkdownMathCommandAvailability()

    private weak var activeTextView: STTextView?

    public init() {}

    func activate(_ textView: STTextView) {
        activeTextView = textView
    }

    func isActive(_ textView: STTextView) -> Bool {
        activeTextView === textView
    }

    func deactivate(_ textView: STTextView) {
        guard activeTextView === textView else { return }
        activeTextView = nil
        publishAvailability(MarkdownMathCommandAvailability())
    }

    /// Publishes availability for the focused editor; results from unfocused
    /// editors are dropped.
    func publish(_ next: MarkdownMathCommandAvailability, for textView: STTextView) {
        guard activeTextView === textView else { return }
        publishAvailability(next)
    }

    private func publishAvailability(_ next: MarkdownMathCommandAvailability) {
        if next != availability {
            availability = next
        }
    }
}
