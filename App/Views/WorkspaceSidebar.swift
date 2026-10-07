import SwiftUI
import WorkspaceKit

/// Sidebar column: Xcode-style navigator selector (Files / Search) above the active navigator.
///
/// The `switch` is load-bearing: Search unmounts in Files mode and mounts a fresh owned
/// query field on return, which the Search focus tests rely on.
struct WorkspaceSidebar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            NavigatorSelector(
                selection: appState.workspaceSearchUI.mode,
                isSearchEnabled: appState.canUseWorkspaceSearch,
                select: { appState.selectWorkspaceSidebarMode($0) }
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            Divider()
                .padding(.horizontal, 10)

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
}

/// Row of navigator icons, like the top of Xcode's navigator area.
private struct NavigatorSelector: View {
    let selection: WorkspaceSidebarMode
    let isSearchEnabled: Bool
    let select: (WorkspaceSidebarMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            item(.files, title: "Files", systemImage: "folder", isEnabled: true)
            item(.search, title: "Search", systemImage: "magnifyingglass", isEnabled: isSearchEnabled)
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar Mode")
        .accessibilityIdentifier(WorkspaceSearchAccessibility.modePicker)
    }

    private func item(
        _ mode: WorkspaceSidebarMode,
        title: String,
        systemImage: String,
        isEnabled: Bool
    ) -> some View {
        let isSelected = selection == mode
        return Button {
            select(mode)
        } label: {
            Image(systemName: systemImage)
                .symbolVariant(isSelected ? .fill : .none)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help(isEnabled || mode == .files ? title : "Open a folder workspace to use Search")
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
