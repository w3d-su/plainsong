import AppKit
import SwiftUI

/// Main window: native split view on macOS 27+ (fixed `HStack` shell before, R17), the
/// document column, and an Xcode-style inspector column.
///
/// Sidebar and inspector visibility are scene state, so each window keeps its own
/// (`docs/window-state-gates.md` §10.1).
struct WorkspaceWindow: View {
    @SceneStorage("plainsong.inspectorPresented") private var storedInspectorPresented = true
    var shellOverride: WorkspaceShell = .automatic
    var inspectorIntentOverride: Binding<Bool>?
    var inspectorVisibilityOverride: InspectorVisibility?
    var sidebarIdealWidth: CGFloat = 256
    var sidebarMinimumWidth: CGFloat = 220

    var body: some View {
        WorkspaceWindowContent(
            inspectorIntent: inspectorIntentOverride ?? $storedInspectorPresented,
            shellOverride: shellOverride,
            sidebarIdealWidth: sidebarIdealWidth,
            sidebarMinimumWidth: sidebarMinimumWidth,
            visibility: inspectorVisibilityOverride
        )
    }
}

enum WorkspaceShell { case automatic, fixed, split }

private struct WorkspaceWindowContent: View {
    @EnvironmentObject private var appState: AppState
    @Binding var inspectorIntent: Bool
    let shellOverride: WorkspaceShell
    let sidebarIdealWidth: CGFloat
    let sidebarMinimumWidth: CGFloat
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @StateObject private var inspectorVisibility: InspectorVisibility
    @SceneStorage("plainsong.inspectorWidth") private var inspectorWidth = InspectorLayout.defaultWidth

    init(
        inspectorIntent: Binding<Bool>,
        shellOverride: WorkspaceShell,
        sidebarIdealWidth: CGFloat,
        sidebarMinimumWidth: CGFloat,
        visibility: InspectorVisibility?
    ) {
        _inspectorIntent = inspectorIntent
        self.shellOverride = shellOverride
        self.sidebarIdealWidth = sidebarIdealWidth
        self.sidebarMinimumWidth = sidebarMinimumWidth
        _inspectorVisibility =
            StateObject(wrappedValue: visibility ?? InspectorVisibility(userIntent: inspectorIntent.wrappedValue))
    }

    var body: some View {
        shell
            .navigationTitle(documentTitle)
            .navigationSubtitle(documentSubtitle)
            .toolbar {
                WorkspaceToolbar(
                    appState: appState,
                    isInspectorPresented: Binding(
                        get: { inspectorVisibility.isPresented },
                        set: { _ in inspectorVisibility.toggle() }
                    )
                )
            }
            .onChange(of: inspectorVisibility.userIntent) { _, intent in
                inspectorIntent = intent
            }
            .onChange(of: inspectorIntent) { _, intent in
                inspectorVisibility.setUserIntent(intent)
            }
            .frame(minWidth: WorkspaceLayout.windowMinimum, minHeight: 420)
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
        if #available(macOS 27.0, *), shellOverride != .fixed {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                WorkspaceSidebar()
                    .navigationSplitViewColumnWidth(min: sidebarMinimumWidth, ideal: sidebarIdealWidth, max: 320)
                    .workspaceFrameProbe("sidebar")
            } detail: {
                documentColumn
            }
        } else {
            HStack(spacing: 0) {
                WorkspaceSidebar()
                    .frame(width: 256)
                    .workspaceFrameProbe("sidebar")
                    .background(SidebarMaterialBackground().ignoresSafeArea())
                Divider()
                documentColumn
            }
        }
    }

    private var documentColumn: some View {
        // R17: all column widths derive from this proxy and constants, never child minima.
        GeometryReader { proxy in
            let minimum = WorkspaceLayout.contentMinimum(preview: appState.isPreviewVisible)
            let visible = inspectorIntent && appState.hasOpenDocument
                && proxy.size.width >= minimum + InspectorLayout.clamped(inspectorWidth) + InspectorLayout.handleWidth
            HStack(spacing: 0) {
                detail
                    .frame(width: max(
                        0,
                        proxy.size
                            .width -
                            (visible ? InspectorLayout.clamped(inspectorWidth) + InspectorLayout.handleWidth : 0)
                    ))
                if visible {
                    InspectorColumn(width: $inspectorWidth) { WorkspaceInspector() }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear { updateInspector(width: proxy.size.width) }
            .onChange(of: proxy.size.width) { _, width in updateInspector(width: width) }
            .onChange(of: inspectorWidth) { _, _ in updateInspector(width: proxy.size.width) }
            .onChange(of: appState.isPreviewVisible) { _, _ in updateInspector(width: proxy.size.width) }
            .onChange(of: appState.hasOpenDocument) { _, _ in updateInspector(width: proxy.size.width) }
        }
    }

    private func updateInspector(width: CGFloat) {
        inspectorVisibility.updateLayout(availableWidth: width, inspectorWidth: inspectorWidth,
                                         contentMinimum: WorkspaceLayout
                                             .contentMinimum(preview: appState.isPreviewVisible),
                                         hasDocument: appState.hasOpenDocument)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            ExportHTMLStatusBanner()
            if appState.workspaceMutationRecoveryBannerPlacement == .global {
                WorkspaceMutationRecoveryBanner()
            }
            GeometryReader { proxy in
                Group {
                    if appState.hasOpenDocument { EditorWorkspace() } else { EmptyEditorState() }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
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
