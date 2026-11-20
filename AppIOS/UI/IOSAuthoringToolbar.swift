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

/// Navigation-bar toolbar content. It also installs the shortcuts declared by
/// 08's `IOSAuthoringAction` descriptors; every tap routes through the
/// scene-scoped `IOSShellActionRouter`. The authoring buttons themselves are
/// in `IOSKeyboardAccessoryBar`.
struct IOSAuthoringToolbarItems: ToolbarContent {
    let scene: IOSShellSceneState
    let router: IOSShellActionRouter

    var body: some ToolbarContent {
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

    /// The keyboard accessory is a UIKit input accessory view and menus are not a
    /// reliable key-command source, so every authoring shortcut except Cmd-F
    /// (on the visible Find button) is mounted once here, on a hidden host that
    /// stays on screen with the navigation bar.
    private var unplacedShortcutActions: [IOSAuthoringAction] {
        router.actions.filter { action in
            guard action.keyEquivalent != nil else { return false }
            switch action.placement {
            case .formatMenu, .toolbarGroup, .toolbar:
                return true
            case .find:
                return action.id != .find
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

    /// The host is hidden; the accessory button or menu row remains the visible
    /// control.
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
