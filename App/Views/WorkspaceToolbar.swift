import SwiftUI

/// Window toolbar: layout switch and inspector toggle (Xcode/Notes keep Open and Save in the
/// File menu). On macOS 26+ the system renders these as Liquid Glass groups.
struct WorkspaceToolbar: ToolbarContent {
    @ObservedObject var appState: AppState
    @Binding var isInspectorPresented: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Layout", selection: layoutBinding) {
                Label("Source", systemImage: "doc.plaintext")
                    .tag(EditorLayoutMode.sourceOnly)
                Label("Source and Preview", systemImage: "rectangle.split.2x1")
                    .tag(EditorLayoutMode.sourcePreview)
                if appState.isExperimentalWYSIWYGAvailable {
                    Label("WYSIWYG (Experimental)", systemImage: "textformat")
                        .tag(EditorLayoutMode.wysiwyg)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .disabled(!appState.hasOpenDocument)
            .help(appState.layoutModeToolbarHelp)
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .disabled(!appState.hasOpenDocument)
            .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
        }
    }

    private var layoutBinding: Binding<EditorLayoutMode> {
        Binding(
            get: { appState.layoutMode },
            set: { appState.setLayoutMode($0) }
        )
    }
}
