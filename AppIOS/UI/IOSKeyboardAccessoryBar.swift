import SwiftUI
import UIKit

/// Keyboard accessory driven by 08's `IOSAuthoringAction` descriptors: undo/redo,
/// frequent actions, Heading and Code menus, and a "Format" overflow menu rather
/// than shrinking below 44 pt targets. Shortcuts are installed by
/// `IOSAuthoringToolbarItems`, which stays mounted without the keyboard.
struct IOSKeyboardAccessoryBar: View {
    @ObservedObject var scene: IOSShellSceneState
    @ObservedObject var router: IOSShellActionRouter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    _ = router.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!scene.chrome.editorFocused || !scene.chrome.editorCanWrite)
                .accessibilityIdentifier("plainsong.ios.toolbar.undo")

                Button {
                    _ = router.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!scene.chrome.editorFocused || !scene.chrome.editorCanWrite)
                .accessibilityIdentifier("plainsong.ios.toolbar.redo")

                ForEach(primaryActions, id: \.id) { action in
                    authoringButton(action)
                }

                ForEach(toolbarGroups) { group in
                    Menu {
                        ForEach(group.actions, id: \.id) { action in
                            overflowButton(action)
                        }
                    } label: {
                        Label(group.name, systemImage: groupSymbol(group.name))
                    }
                    .accessibilityLabel(group.name)
                }

                if !overflowActions.isEmpty {
                    Menu {
                        ForEach(overflowActions, id: \.id) { action in
                            overflowButton(action)
                        }
                    } label: {
                        Label("Format", systemImage: "textformat")
                    }
                    .accessibilityIdentifier("plainsong.ios.toolbar.formatMenu")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IOSKeyboardAccessoryButtonStyle())
            .padding(.horizontal, 8)
        }
        .frame(height: IOSKeyboardAccessoryInputView.barHeight)
    }

    private struct ToolbarGroup: Identifiable {
        let name: String
        let actions: [IOSAuthoringAction]
        var id: String {
            name
        }
    }

    /// Frequent commands stay as 44 pt icon buttons. Heading and code commands
    /// stay in menus so the keyboard accessory does not overflow on iPhone.
    private var primaryActions: [IOSAuthoringAction] {
        router.actions.filter { action in
            if case .toolbar = action.placement {
                return true
            }
            return false
        }
    }

    private var toolbarGroups: [ToolbarGroup] {
        var order: [String] = []
        var grouped: [String: [IOSAuthoringAction]] = [:]
        for action in router.actions {
            guard case let .toolbarGroup(name) = action.placement else { continue }
            if grouped[name] == nil {
                order.append(name)
            }
            grouped[name, default: []].append(action)
        }
        return order.map { ToolbarGroup(name: $0, actions: grouped[$0] ?? []) }
    }

    private var overflowActions: [IOSAuthoringAction] {
        router.actions.filter { $0.placement == .formatMenu }
    }

    private func groupSymbol(_ name: String) -> String {
        switch name {
        case "Heading": "textformat.size"
        case "Code": "chevron.left.forwardslash.chevron.right"
        default: "textformat"
        }
    }

    private func authoringButton(_ action: IOSAuthoringAction) -> some View {
        Button {
            _ = router.perform(action.id)
        } label: {
            Label(action.title, systemImage: symbol(for: action.id))
        }
        .disabled(!router.isEnabled(action.id))
        .accessibilityLabel(action.accessibilityLabel)
    }

    private func symbol(for id: IOSAuthoringActionID) -> String {
        switch id {
        case .bold: "bold"
        case .italic: "italic"
        case .link: "link"
        default: "textformat"
        }
    }

    private func overflowButton(_ action: IOSAuthoringAction) -> some View {
        Button(action.title) {
            _ = router.perform(action.id)
        }
        .disabled(!router.isEnabled(action.id))
        .accessibilityLabel(action.accessibilityLabel)
    }
}

private struct IOSKeyboardAccessoryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1) : 0.35)
    }
}

/// SwiftUI's `.keyboard` toolbar placement reaches only SwiftUI text inputs. The
/// source editor is a `UITextView`, so the bar is its `inputAccessoryView`.
final class IOSKeyboardAccessoryInputView: UIInputView {
    static let barHeight: CGFloat = 44

    private let host: UIHostingController<IOSKeyboardAccessoryBar>
    private weak var router: IOSShellActionRouter?

    init(scene: IOSShellSceneState, router: IOSShellActionRouter) {
        host = UIHostingController(rootView: IOSKeyboardAccessoryBar(scene: scene, router: router))
        self.router = router
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: Self.barHeight),
            inputViewStyle: .keyboard
        )
        autoresizingMask = .flexibleWidth
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Installs one bar per (text view, router). Any other hosted editor view is
    /// left alone.
    static func install(on editorView: UIView?, scene: IOSShellSceneState, router: IOSShellActionRouter) {
        guard let textView = editorView as? UITextView else { return }
        if let installed = textView.inputAccessoryView as? IOSKeyboardAccessoryInputView,
           installed.router === router
        {
            return
        }
        textView.inputAccessoryView = IOSKeyboardAccessoryInputView(scene: scene, router: router)
        if textView.isFirstResponder {
            textView.reloadInputViews()
        }
    }

    /// The hosted bar keeps its scene alive, and the scene retains the text view.
    /// Removing the bar breaks that cycle when the editor leaves the screen or
    /// its scene shuts down.
    static func uninstall(from editorView: UIView?) {
        guard let textView = editorView as? UITextView,
              textView.inputAccessoryView is IOSKeyboardAccessoryInputView else { return }
        textView.inputAccessoryView = nil
        if textView.isFirstResponder {
            textView.reloadInputViews()
        }
    }
}
