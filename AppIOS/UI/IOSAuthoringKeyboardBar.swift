import SwiftUI
import UIKit

/// Undo/redo, the frequent formatting commands and the Format menus, at the
/// bottom of the document column while the source pane shows. The software
/// keyboard pushes it up, so it sits directly above the keys.
///
/// This is an ordinary view at the bottom of the document column, not
/// `ToolbarItemGroup(placement: .keyboard)`: SwiftUI attaches that placement
/// only to its own text inputs, so with the UIKit editor the group never
/// appeared and its shortcuts were never installed.
struct IOSAuthoringKeyboardBar: View {
    @ObservedObject var scene: IOSShellSceneState
    @ObservedObject var router: IOSShellActionRouter

    @State private var keyboardIsUp = false

    var body: some View {
        HStack(spacing: 0) {
            commands
            if keyboardIsUp {
                Divider().frame(height: 24)
                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                    )
                } label: {
                    Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down")
                }
                .accessibilityIdentifier("plainsong.ios.toolbar.hideKeyboard")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(IOSKeyboardBarButtonStyle())
        .frame(height: 44)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .background {
            // In the navigation bar these hosts were drawn: an iPad showed their
            // titles on top of each other, an iPhone listed them under More.
            ZStack {
                ForEach(unplacedShortcutActions, id: \.id) { action in
                    shortcutHost(action)
                }
            }
            .buttonStyle(.plain)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsUp = false
        }
    }

    private var commands: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button {
                    _ = router.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!scene.chrome.editorFocused || !scene.chrome.editorCanWrite)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier("plainsong.ios.toolbar.undo")

                Button {
                    _ = router.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!scene.chrome.editorFocused || !scene.chrome.editorCanWrite)
                .keyboardShortcut("z", modifiers: [.command, .shift])
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
            .menuStyle(.button)
            .padding(.horizontal, 8)
        }
    }

    private struct ToolbarGroup: Identifiable {
        let name: String
        let actions: [IOSAuthoringAction]
        var id: String {
            name
        }
    }

    /// Frequent commands stay as 44 pt icon buttons. Heading and code commands
    /// stay in menus so the bar does not overflow on iPhone.
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

    private func groupSymbol(_ name: String) -> String {
        switch name {
        case "Heading": "textformat.size"
        case "Code": "chevron.left.forwardslash.chevron.right"
        default: "textformat"
        }
    }

    private var overflowActions: [IOSAuthoringAction] {
        router.actions.filter { $0.placement == .formatMenu }
    }

    private func authoringButton(_ action: IOSAuthoringAction) -> some View {
        Button {
            _ = router.perform(action.id)
        } label: {
            Label(action.title, systemImage: symbol(for: action.id))
        }
        .disabled(!router.isEnabled(action.id))
        .accessibilityLabel(action.accessibilityLabel)
        .modifier(AuthoringShortcutModifier(action: action))
    }

    private func symbol(for id: IOSAuthoringActionID) -> String {
        switch id {
        case .bold: "bold"
        case .italic: "italic"
        case .link: "link"
        default: "textformat"
        }
    }

    /// Menus are not a reliable key-command source, and Find Next / Find
    /// Previous / Use Selection have no always-visible control. Mount the same
    /// installer so those shortcuts exist while the toolbar is on screen.
    /// Cmd-F stays on the visible Find button. Primary buttons install their
    /// own shortcuts and are not repeated here.
    private var unplacedShortcutActions: [IOSAuthoringAction] {
        router.actions.filter { action in
            guard action.keyEquivalent != nil else { return false }
            switch action.placement {
            case .formatMenu, .toolbarGroup:
                return true
            case .find:
                return action.id != .find
            case .toolbar:
                return false
            }
        }
    }

    /// Menu rows are not a reliable key-command source, so format and find
    /// commands are also mounted here with the same installer. The host is
    /// hidden; the menu row remains the visible control. Primary shortcuts
    /// stay on their buttons and are not repeated here.
    private func shortcutHost(_ action: IOSAuthoringAction) -> some View {
        Button(action.title) {
            _ = router.perform(action.id)
        }
        .disabled(!router.isEnabled(action.id))
        .accessibilityLabel(action.accessibilityLabel)
        .modifier(AuthoringShortcutModifier(action: action))
        .accessibilityHidden(true)
        .frame(width: 1, height: 1)
    }

    private func overflowButton(_ action: IOSAuthoringAction) -> some View {
        Button(action.title) {
            _ = router.perform(action.id)
        }
        .disabled(!router.isEnabled(action.id))
        .accessibilityLabel(action.accessibilityLabel)
    }
}

/// A 44 pt target per control without the bordered chrome of a toolbar.
private struct IOSKeyboardBarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}
