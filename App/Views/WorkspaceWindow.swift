import AppKit
import SwiftUI

/// Main window: native split view on macOS 27+ (fixed `HStack` shell before, R17), the
/// document column, and an Xcode-style inspector column.
///
/// Inspector intent and width are scene state. Visibility is derived from the document
/// column (`docs/window-state-gates.md` §10.1). The `HStack` shell's minimum is 780 pt;
/// the split shell's is the widest sidebar, the measured chrome, and the Split floor.
/// The inspector auto-collapses when that column cannot fit it.
struct WorkspaceWindow: View {
    @SceneStorage("plainsong.inspectorPresented") private var storedInspectorPresented = true
    @SceneStorage("plainsong.inspectorWidth") private var storedInspectorWidth = InspectorLayout.defaultWidth
    var shellOverride: WorkspaceShell = .automatic
    var inspectorIntentOverride: Binding<Bool>?
    var inspectorWidthOverride: Binding<Double>?
    var inspectorVisibilityOverride: InspectorVisibility?
    var sidebarIdealWidth: CGFloat = 256
    var sidebarMinimumWidth: CGFloat = 220

    var body: some View {
        WorkspaceWindowContent(
            inspectorIntent: inspectorIntentOverride ?? $storedInspectorPresented,
            inspectorWidth: inspectorWidthOverride ?? $storedInspectorWidth,
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
    @Binding var inspectorWidth: Double
    let shellOverride: WorkspaceShell
    let sidebarIdealWidth: CGFloat
    let sidebarMinimumWidth: CGFloat
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @StateObject private var inspectorVisibility: InspectorVisibility
    /// Drops superseded geometry updates so a late publish cannot collapse a newer width.
    @State private var inspectorLayoutGeneration = 0

    init(
        inspectorIntent: Binding<Bool>,
        inspectorWidth: Binding<Double>,
        shellOverride: WorkspaceShell,
        sidebarIdealWidth: CGFloat,
        sidebarMinimumWidth: CGFloat,
        visibility: InspectorVisibility?
    ) {
        _inspectorIntent = inspectorIntent
        _inspectorWidth = inspectorWidth
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
            .frame(minWidth: windowMinimum, minHeight: 420)
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
                    contentMinWidth: windowMinimum,
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
        // Visibility is `inspectorVisibility.isPresented` only. The geometry publish is
        // deferred so it does not run inside this reader.
        GeometryReader { proxy in
            let contentMinimum = WorkspaceLayout.contentMinimum(preview: appState.isPreviewVisible)
            // Store the measured column without publishing. Show reads this during the same
            // layout; `applyRecordedLayout` still waits until the next turn.
            // `let _` is required: a bare discard is not a ViewBuilder statement.
            // swiftlint:disable:next redundant_discardable_let
            let _ = inspectorVisibility.recordLayout(
                availableWidth: proxy.size.width,
                inspectorWidth: inspectorWidth,
                contentMinimum: contentMinimum,
                hasDocument: appState.hasOpenDocument
            )
            let presented = inspectorVisibility.isPresented
            let reserved = InspectorLayout.clamped(inspectorWidth) + InspectorLayout.handleWidth
            HStack(spacing: 0) {
                detail
                    .frame(width: max(0, proxy.size.width - (presented ? reserved : 0)))
                if presented {
                    InspectorColumn(
                        width: $inspectorWidth,
                        availableWidth: proxy.size.width,
                        contentMinimum: contentMinimum
                    ) { WorkspaceInspector() }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .workspaceFrameProbe("document")
            .onAppear { publishInspectorLayout(width: proxy.size.width) }
            .onChange(of: proxy.size.width) { _, width in publishInspectorLayout(width: width) }
            .onChange(of: inspectorWidth) { _, _ in publishInspectorLayout(width: proxy.size.width) }
            .onChange(of: appState.isPreviewVisible) { _, _ in publishInspectorLayout(width: proxy.size.width) }
            .onChange(of: appState.hasOpenDocument) { _, _ in publishInspectorLayout(width: proxy.size.width) }
        }
    }

    /// Records the column immediately and publishes visibility on the next turn, so a view
    /// update does not publish and Show still sees the latest width.
    private func publishInspectorLayout(width: CGFloat) {
        inspectorVisibility.recordLayout(
            availableWidth: width,
            inspectorWidth: inspectorWidth,
            contentMinimum: WorkspaceLayout.contentMinimum(preview: appState.isPreviewVisible),
            hasDocument: appState.hasOpenDocument
        )
        inspectorLayoutGeneration += 1
        let generation = inspectorLayoutGeneration
        Task { @MainActor in
            await Task.yield()
            guard generation == inspectorLayoutGeneration else { return }
            inspectorVisibility.applyRecordedLayout()
        }
    }

    /// Matches `shell`: split view only on macOS 27 when the shell is not forced fixed.
    private var usesSplitShell: Bool {
        guard shellOverride != .fixed else { return false }
        if #available(macOS 27.0, *) { return true }
        return false
    }

    private var windowMinimum: CGFloat {
        WorkspaceLayout.windowMinimum(splitShell: usesSplitShell)
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
