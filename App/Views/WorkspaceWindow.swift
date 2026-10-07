import AppKit
import SwiftUI

/// Main window: native split view on macOS 27+ (fixed `HStack` shell before, R17), the
/// document column, and an Xcode-style inspector column.
///
/// Sidebar and inspector visibility are scene state, so each window keeps its own
/// (`docs/window-state-gates.md` §10.1).
struct WorkspaceWindow: View {
    @EnvironmentObject private var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @SceneStorage("plainsong.inspectorPresented") private var storedInspectorPresented = true
    @StateObject private var inspectorVisibility = InspectorVisibility()
    @SceneStorage("plainsong.inspectorWidth") private var inspectorWidth = InspectorLayout.defaultWidth

    var body: some View {
        shell
            .navigationTitle(documentTitle)
            .navigationSubtitle(documentSubtitle)
            .toolbar {
                WorkspaceToolbar(appState: appState, isInspectorPresented: $inspectorVisibility.isPresented)
            }
            .onAppear {
                inspectorVisibility.isPresented = storedInspectorPresented
            }
            .onChange(of: inspectorVisibility.isPresented) { _, isPresented in
                storedInspectorPresented = isPresented
            }
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
                    isDocumentEdited: appState.currentDocument.isDirty,
                    onWindow: { inspectorVisibility.attach(to: $0) }
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

    /// R17: on macOS 15, STTextView's layout re-requests Update Constraints through the split
    /// view's constraint-based host until AppKit throws (large documents and 10,000-match Find
    /// on the CI runner). The split view is verified only on macOS 27, so everything earlier
    /// keeps the fixed-width `HStack` shell that predates it.
    @ViewBuilder
    private var shell: some View {
        if #available(macOS 27.0, *) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                WorkspaceSidebar()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 256, max: 320)
            } detail: {
                documentColumn
            }
        } else {
            HStack(spacing: 0) {
                WorkspaceSidebar()
                    .frame(width: 256)
                    .background(SidebarMaterialBackground().ignoresSafeArea())
                Divider()
                documentColumn
            }
        }
    }

    private var documentColumn: some View {
        HStack(spacing: 0) {
            detail
            if showsInspector {
                InspectorColumn(width: $inspectorWidth) {
                    WorkspaceInspector()
                }
            }
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
        inspectorVisibility.isPresented && appState.hasOpenDocument
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
