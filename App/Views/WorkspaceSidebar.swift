import SwiftUI
import WorkspaceKit

/// Fixed-width workspace sidebar shell: Files / Search mode selector + content.
///
/// Keeps the stable `HStack` host in `WorkspaceWindow` — never `NavigationSplitView` (R17).
struct WorkspaceSidebar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            modeSelector
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            Group {
                switch appState.workspaceSearchUI.mode {
                case .files:
                    WorkspaceFilesSidebar()
                case .search:
                    WorkspaceSearchSidebar()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var modeSelector: some View {
        Picker("Sidebar Mode", selection: modeBinding) {
            Text("Files").tag(WorkspaceSidebarMode.files)
            Text("Search").tag(WorkspaceSidebarMode.search)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Sidebar Mode")
        .accessibilityIdentifier(WorkspaceSearchAccessibility.modePicker)
        .disabled(!appState.canUseWorkspaceSearch && appState.workspaceSearchUI.mode == .files)
        .help(
            appState.canUseWorkspaceSearch
                ? "Switch between Files and Search"
                : "Open a folder workspace to use Search"
        )
    }

    private var modeBinding: Binding<WorkspaceSidebarMode> {
        Binding(
            get: { appState.workspaceSearchUI.mode },
            set: { appState.selectWorkspaceSidebarMode($0) }
        )
    }
}
