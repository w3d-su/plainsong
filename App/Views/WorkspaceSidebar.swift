import SwiftUI
import WorkspaceKit

/// Fixed-width workspace sidebar shell: Files / Search mode selector + content.
///
/// Keeps the stable `HStack` host in `WorkspaceWindow` — never `NavigationSplitView` (R17) —
/// but draws the system sidebar material so it reads as a native source list.
struct WorkspaceSidebar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            modeSelector
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

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
        .background(SidebarMaterialBackground().ignoresSafeArea())
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
