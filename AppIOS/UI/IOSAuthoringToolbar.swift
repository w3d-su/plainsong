import SwiftUI

extension EventModifiers {
    init(_ modifiers: IOSKeyboardModifiers) {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
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

            if !overflowActions.isEmpty {
                Menu {
                    ForEach(overflowActions, id: \.id) { action in
                        Button(action.title) {
                            _ = router.perform(action.id)
                        }
                        .disabled(!router.isEnabled(action.id))
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

            Button {
                _ = router.perform(.find)
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .disabled(!scene.chrome.hasDocument)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityIdentifier("plainsong.ios.toolbar.find")

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

    private var primaryActions: [IOSAuthoringAction] {
        router.actions.filter { action in
            if case .toolbar = action.placement { return true }
            if case .toolbarGroup = action.placement { return true }
            return false
        }
    }

    private var overflowActions: [IOSAuthoringAction] {
        router.actions.filter { $0.placement == .formatMenu }
    }

    private func authoringButton(_ action: IOSAuthoringAction) -> some View {
        let button = Button(action.title) {
            _ = router.perform(action.id)
        }
        .disabled(!router.isEnabled(action.id))
        .accessibilityLabel(action.accessibilityLabel)
        if let key = action.keyEquivalent {
            return AnyView(button.keyboardShortcut(key, modifiers: EventModifiers(action.keyboardModifiers)))
        }
        return AnyView(button)
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
