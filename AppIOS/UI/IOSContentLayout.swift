import CoreFoundation
import Foundation

/// Which single pane occupies the document area when the shell is in toggle mode.
enum IOSEditorPane: Hashable {
    case source
    case preview
}

/// How the document area arranges the *same* editor and preview instances.
/// This is only ever a visibility/geometry change: both panes stay mounted.
enum IOSContentLayout: Equatable {
    /// Compact width, or regular width with a content area narrower than 900 pt.
    /// The payload is the pane currently on top.
    case single(IOSEditorPane)
    /// Regular width with content area >= 900 pt: editor and preview side by side.
    case sideBySide
}

/// Pure layout rule (handoff 10): decide from the actual content width of the
/// document area — never the device model — so iPad Split View / Stage Manager
/// and an open sidebar land in the right mode.
enum IOSContentLayoutPolicy {
    static let sideBySideMinimumContentWidth: CGFloat = 900

    static func layout(
        prefersRegularWidth: Bool,
        contentWidth: CGFloat,
        preferredPane: IOSEditorPane
    ) -> IOSContentLayout {
        if prefersRegularWidth, contentWidth >= sideBySideMinimumContentWidth {
            return .sideBySide
        }
        return .single(preferredPane)
    }
}
