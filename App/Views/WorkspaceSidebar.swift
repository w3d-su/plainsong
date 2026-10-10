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
            // Same row as the document's jump bar, so the capsule's bottom meets its divider
            // and its top stays clear of the toolbar above.
            .frame(height: DocumentJumpBar.height, alignment: .bottom)
            .padding(.bottom, 6)

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

/// Navigator icons in a small Liquid Glass capsule, like Xcode's navigator bar: outlined
/// symbols, the selected one full-strength on a sliding highlight.
private struct NavigatorSelector: View {
    let selection: WorkspaceSidebarMode
    let isSearchEnabled: Bool
    let select: (WorkspaceSidebarMode) -> Void

    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            item(.files, title: "Files", systemImage: "folder", isEnabled: true)
            item(.search, title: "Search", systemImage: "magnifyingglass", isEnabled: isSearchEnabled)
        }
        .padding(2)
        .plainsongGlass(in: Capsule())
        .animation(.snappy(duration: 0.25), value: selection)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 20)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(.primary.opacity(0.16))
                            .matchedGeometryEffect(id: "selection", in: highlight)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isEnabled || mode == .files ? title : "Open a folder workspace to use Search")
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
