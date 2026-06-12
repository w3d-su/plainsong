import EditorKit
import MarkdownCore
import PreviewKit
import SwiftUI
import WorkspaceKit

/// Main window: sidebar + editor split (agent.md §4).
/// M0 placeholder — proves all four packages link. M1 replaces the detail pane
/// with the real editor.
struct WorkspaceWindow: View {
    var body: some View {
        NavigationSplitView {
            List {
                Text("No workspace open")
                    .foregroundStyle(.secondary)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("BlogEditor")
                    .font(.largeTitle.weight(.semibold))
                Text("M0 scaffold — linked: \(linkedPackages)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var linkedPackages: String {
        [
            "MarkdownCore \(MarkdownCoreInfo.version)",
            "EditorKit \(EditorKitInfo.version)",
            "PreviewKit \(PreviewKitInfo.version)",
            "WorkspaceKit \(WorkspaceKitInfo.version)",
        ].joined(separator: " · ")
    }
}

#Preview {
    WorkspaceWindow()
}
