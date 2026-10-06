import AppKit
import SwiftUI

/// An owned AppKit button for the find bar's replacement controls (Replace PR H).
///
/// AppKit rather than SwiftUI `Button`, for three reasons:
/// - Full Keyboard Access focuses and presses an `NSButton` natively, and its focus is a real
///   AppKit first responder that `EditorFindResponderSupport` can recognize as bar provenance;
/// - focusing it reports nothing to SwiftUI `FocusState`, so Tab onto **Cancel** cannot advance
///   the Replace authority generation and supersede the plan it is about to cancel;
/// - hosted tests can click the real control (`performClick`), which runs the same
///   target/action path a mouse click or a Full Keyboard Access Space press runs.
struct EditorFindBarButton: NSViewRepresentable {
    enum Style: Equatable {
        case push
        /// A native disclosure triangle; `isExpanded` drives its on/off state.
        case disclosure(isExpanded: Bool)
    }

    let title: String
    let identifier: String
    var accessibilityLabel: String?
    var accessibilityHelp: String?
    var style: Style = .push
    var isEnabled = true
    /// Focus hand-off when this button leaves its window while focused (see `EditorFindOwnedButton`).
    var onRemovalWhileFocused: ((NSWindow) -> Void)?
    var onEscape: (() -> Void)?
    /// Receives the window hosting the pressed button, so App can refuse a press in a window
    /// that is not key (a VoiceOver press on a background window's bar).
    let action: (NSWindow?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = EditorFindOwnedButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.invokeAction(_:))
        )
        switch style {
        case .push:
            button.bezelStyle = .push
            button.controlSize = .regular
        case .disclosure:
            button.title = ""
            button.bezelStyle = .disclosure
            button.setButtonType(.pushOnPushOff)
        }
        button.setAccessibilityIdentifier(identifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        configure(button)
    }

    /// The disclosure's accessibility value comes from AppKit's own `state`; only the label
    /// and help are supplied here.
    private func configure(_ button: NSButton) {
        if case let .disclosure(isExpanded) = style {
            button.state = isExpanded ? .on : .off
        } else if button.title != title {
            button.title = title
        }
        // Disabling a focused button resigns it to the window; hand focus to a surviving
        // bar control first, the same contract as removal.
        if !isEnabled, let window = button.window, window.firstResponder === button {
            (button as? EditorFindOwnedButton)?.onRemovalWhileFocused?(window)
        }
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(accessibilityLabel ?? title)
        button.setAccessibilityHelp(accessibilityHelp)
        if let owned = button as? EditorFindOwnedButton {
            owned.onRemovalWhileFocused = onRemovalWhileFocused
            owned.onEscape = onEscape
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: (NSWindow?) -> Void

        init(action: @escaping (NSWindow?) -> Void) {
            self.action = action
        }

        @objc func invokeAction(_ sender: Any?) {
            action((sender as? NSView)?.window)
        }
    }
}

/// An owned AppKit status label for the replacement row: progress, result, refusal, blocked,
/// overflow, and field-error text. The text is the whole message — states are never conveyed
/// by color alone — and VoiceOver speaks it as the label's value. No accessibility label is
/// set on top, which would make VoiceOver say it twice.
struct EditorFindBarLabel: NSViewRepresentable {
    let text: String
    let identifier: String
    var isSecondary = false

    func makeNSView(context _: Context) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier(identifier)
        configure(label)
        return label
    }

    func updateNSView(_ label: NSTextField, context _: Context) {
        configure(label)
    }

    private func configure(_ label: NSTextField) {
        if label.stringValue != text {
            label.stringValue = text
        }
        label.textColor = isSecondary ? .secondaryLabelColor : .labelColor
    }
}
