import SwiftUI

extension EventModifiers {
    init(_ modifiers: IOSKeyboardModifiers) {
        var result: EventModifiers = []
        if modifiers.contains(.command) {
            result.insert(.command)
        }
        if modifiers.contains(.shift) {
            result.insert(.shift)
        }
        if modifiers.contains(.option) {
            result.insert(.option)
        }
        if modifiers.contains(.control) {
            result.insert(.control)
        }
        self = result
    }
}

extension IOSAuthoringAction {
    /// `keyboardInput` is a single character ("b", "0", "g"); anything else is
    /// not a `KeyEquivalent` and is installed without a shortcut.
    var keyEquivalent: KeyEquivalent? {
        guard let input = keyboardInput, let character = input.first, input.count == 1 else {
            return nil
        }
        return KeyEquivalent(character)
    }
}

/// One installer for every placement. Menu rows and find commands use it too;
/// a plain `Button` does not install the descriptor's shortcut.
struct AuthoringShortcutModifier: ViewModifier {
    let action: IOSAuthoringAction

    func body(content: Content) -> some View {
        if let key = action.keyEquivalent {
            content.keyboardShortcut(key, modifiers: EventModifiers(action.keyboardModifiers))
        } else {
            content
        }
    }
}

/// Toolbar content driven by 08's `IOSAuthoringAction` descriptors. The shell
/// installs buttons and their declared shortcuts; every tap routes through the
/// scene-scoped `IOSShellActionRouter`. Items that don't fit in the primary
/// row collapse into an accessible "Format" overflow menu rather than
/// shrinking below 44 pt targets.
struct IOSAuthoringToolbarItems: ToolbarContent {
    let scene: IOSShellSceneState
    let router: IOSShellActionRouter

    var body: some ToolbarContent {
        // iPhone/iPad keyboard accessory: undo/redo, frequent actions, Format
        // overflow, find. Presented above the hardware or software keyboard.
        ToolbarItemGroup(placement: .keyboard) {
            Button {
                _ = router.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn backward")
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

        // Top-right: save, find, frontmatter inspector, image insertion.
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                scene.saveCurrentDocument()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!scene.chrome.canSave)
            .keyboardShortcut("s", modifiers: .command)
            .accessibilityIdentifier("plainsong.ios.toolbar.save")

            if let export = scene.surfaces.exportDocument {
                Menu {
                    Button("Export as HTML") { export(.html) }
                        .disabled(scene.exportStatus != nil)
                    Button("Export as PDF") { export(.pdf) }
                        .disabled(scene.exportStatus != nil)
                    Button("Print") { export(.print) }
                        .disabled(scene.exportStatus != nil)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!scene.chrome.hasDocument || scene.exportStatus != nil)
                .accessibilityIdentifier("plainsong.ios.toolbar.export")
            }

            findButton

            workspaceSearchButton

            ForEach(unplacedShortcutActions, id: \.id) { action in
                shortcutHost(action)
            }

            Button {
                router.presentFrontmatter()
            } label: {
                Label("Frontmatter", systemImage: "doc.badge.gearshape")
            }
            .disabled(!scene.chrome.hasDocument)
            .accessibilityIdentifier("plainsong.ios.toolbar.frontmatter")

            if scene.surfaces.imageInsertion != nil {
                Button {
                    router.presentImagePicker()
                } label: {
                    Label("Insert Image", systemImage: "photo")
                }
                .disabled(!scene.chrome.hasDocument || !scene.chrome.editorCanWrite)
                .accessibilityIdentifier("plainsong.ios.toolbar.insertImage")
            }
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

    private var workspaceSearchButton: some View {
        Button {
            scene.presentWorkspaceSearch()
        } label: {
            Label("Search in Workspace", systemImage: "text.magnifyingglass")
        }
        .disabled(!scene.chrome.hasWorkspace)
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .accessibilityIdentifier("plainsong.ios.toolbar.workspaceSearch")
        .accessibilityHint("Search Markdown files in the open folder")
    }

    private var findButton: some View {
        let button = Button {
            _ = router.perform(.find)
        } label: {
            Label("Find", systemImage: "magnifyingglass")
        }
        .disabled(!scene.chrome.hasDocument)
        .accessibilityIdentifier("plainsong.ios.toolbar.find")
        if let find = router.actions.first(where: { $0.id == .find }), find.keyEquivalent != nil {
            return AnyView(button.modifier(AuthoringShortcutModifier(action: find)))
        }
        return AnyView(button.keyboardShortcut("f", modifiers: .command))
    }

    private func authoringButton(_ action: IOSAuthoringAction) -> some View {
        Button {
            _ = router.perform(action.id)
        } label: {
            Label(action.title, systemImage: symbol(for: action.id))
                .labelStyle(.iconOnly)
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

    private func overflowButton(_ action: IOSAuthoringAction) -> some View {
        Button(action.title) {
            _ = router.perform(action.id)
        }
        .disabled(!router.isEnabled(action.id))
        .accessibilityLabel(action.accessibilityLabel)
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
}

/// Source/preview toggle for single-pane (compact or narrow) layouts.
/// Switching panes only changes container visibility — both stay mounted.
struct IOSPaneToggle: View {
    @ObservedObject var scene: IOSShellSceneState

    var body: some View {
        if case let .single(pane) = scene.layout {
            Picker("View", selection: Binding(
                get: { pane },
                set: { scene.showPane($0) }
            )) {
                Text("Source").tag(IOSEditorPane.source)
                Text("Preview").tag(IOSEditorPane.preview)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .accessibilityIdentifier("plainsong.ios.paneToggle")
        }
    }
}
