import SwiftUI

/// Invisible buttons that install the shortcuts of commands with no visible
/// button of their own. Menu rows are not a reliable key-command source, and
/// Find Next, Find Previous and Use Selection have no always-visible control.
/// The hosts are a hidden background: in the navigation bar they were drawn
/// (an iPad showed their titles on top of each other, an iPhone listed them
/// under More).
struct IOSAuthoringShortcutHosts: View {
    enum Group {
        /// Format-menu and toolbar-group commands. The keyboard bar mounts
        /// these, so they exist while the source pane shows.
        case formatting
        /// Find Next, Find Previous and Use Selection. The document column
        /// mounts these in every layout: the Find button (⌘F) stays in the
        /// navigation bar while the preview shows, and its follow-up keys must
        /// work there too. ⌘F stays on that visible button.
        case find
    }

    @ObservedObject var scene: IOSShellSceneState
    @ObservedObject var router: IOSShellActionRouter
    let group: Group

    var body: some View {
        ZStack {
            ForEach(Self.actions(in: group, from: router.actions), id: \.id) { action in
                host(action)
            }
        }
        .buttonStyle(.plain)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Primary commands install their shortcuts on their own buttons and are
    /// not repeated here.
    static func actions(in group: Group, from actions: [IOSAuthoringAction]) -> [IOSAuthoringAction] {
        actions.filter { action in
            guard action.keyEquivalent != nil else { return false }
            switch action.placement {
            case .formatMenu, .toolbarGroup:
                return group == .formatting
            case .find:
                return group == .find && action.id != .find
            case .toolbar:
                return false
            }
        }
    }

    private func host(_ action: IOSAuthoringAction) -> some View {
        Button(action.title) {
            _ = router.perform(action.id)
        }
        .disabled(!router.isEnabled(action.id))
        .accessibilityLabel(action.accessibilityLabel)
        .modifier(AuthoringShortcutModifier(action: action))
        .accessibilityHidden(true)
        .frame(width: 1, height: 1)
    }
}
