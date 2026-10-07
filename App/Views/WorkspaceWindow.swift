import AppKit
import SwiftUI

/// Main window: native split view (floating glass sidebar on macOS 26+), the document
/// column, and an Xcode-style inspector column.
///
/// Sidebar and inspector visibility are scene state, so each window keeps its own
/// (`docs/window-state-gates.md` §10.1).
struct WorkspaceWindow: View {
    @EnvironmentObject private var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @SceneStorage("plainsong.inspectorPresented") private var isInspectorPresented = true
    @SceneStorage("plainsong.inspectorWidth") private var inspectorWidth = InspectorLayout.defaultWidth

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 256, max: 320)
        } detail: {
            HStack(spacing: 0) {
                detail
                if showsInspector {
                    InspectorColumn(width: $inspectorWidth) {
                        WorkspaceInspector()
                    }
                }
            }
        }
        .navigationTitle(documentTitle)
        .navigationSubtitle(documentSubtitle)
        .toolbar {
            WorkspaceToolbar(appState: appState, isInspectorPresented: $isInspectorPresented)
        }
        .focusedSceneValue(\.inspectorVisibility, $isInspectorPresented)
        .frame(minWidth: 760, minHeight: 420)
        .alert(
            appState.presentedError?.title ?? "Error",
            isPresented: errorIsPresented
        ) {
            Button("OK") {
                appState.dismissError()
            }
        } message: {
            Text(appState.presentedError?.message ?? "")
        }
        .background(
            WindowMetadataAccessor(
                representedURL: appState.currentDocument.fileURL,
                isDocumentEdited: appState.currentDocument.isDirty
            )
        )
        .task {
            await Task.yield()
            appState.restoreLastOpenedFileIfNeeded()
            #if DEBUG
                appState.showExportHTMLFeedbackSmokeIfRequested()
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            appState.flushAutosaveAfterWindowResignedKey()
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            ExportHTMLStatusBanner()
            if appState.workspaceMutationRecoveryBannerPlacement == .global {
                WorkspaceMutationRecoveryBanner()
            }

            // R17: a split column whose minimum size follows its content (editor, web view)
            // re-enters AppKit's Update Constraints pass until the window throws. The
            // GeometryReader gives the column a fixed, content-independent minimum.
            GeometryReader { proxy in
                Group {
                    if appState.hasOpenDocument {
                        EditorWorkspace()
                    } else {
                        EmptyEditorState()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private var showsInspector: Bool {
        isInspectorPresented && appState.hasOpenDocument
    }

    private var documentTitle: String {
        if let fileURL = appState.currentDocument.fileURL {
            return fileURL.lastPathComponent
        }
        if appState.hasOpenDocument {
            return "Untitled"
        }
        return appState.workspaceRootURL?.lastPathComponent ?? "Plainsong"
    }

    private var documentSubtitle: String {
        guard appState.hasOpenDocument else { return "" }
        if let rootURL = appState.workspaceRootURL {
            return rootURL.lastPathComponent
        }
        return appState.currentDocument.fileURL?.deletingLastPathComponent().lastPathComponent ?? ""
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { appState.presentedError != nil },
            set: { isPresented in
                if !isPresented {
                    appState.dismissError()
                }
            }
        )
    }
}

#Preview {
    WorkspaceWindow()
        .environmentObject(AppState())
}
