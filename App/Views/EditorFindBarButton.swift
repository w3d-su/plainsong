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
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
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

    private func configure(_ button: NSButton) {
        if case let .disclosure(isExpanded) = style {
            button.state = isExpanded ? .on : .off
        } else if button.title != title {
            button.title = title
        }
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(accessibilityLabel ?? title)
        button.setAccessibilityHelp(accessibilityHelp)
        if case let .disclosure(isExpanded) = style {
            button.setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func invokeAction(_: Any?) {
            action()
        }
    }
}

/// An owned AppKit status label for the replacement row: progress, result, refusal, blocked,
/// overflow, and field-error text. The text is the whole message — states are never conveyed
/// by color alone — and it is also the accessibility label VoiceOver speaks.
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
        label.setAccessibilityLabel(text)
    }
}
