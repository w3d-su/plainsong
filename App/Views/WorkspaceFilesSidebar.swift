import AppKit
import SwiftUI
import WorkspaceKit

/// Files navigator: workspace tree with glass Add/Filter controls (WS3C Files mode).
///
/// The tree is a native source list: selection, keyboard navigation, and the inactive-window
/// highlight come from `List(selection:)`. Only editable Markdown rows are selectable, and
/// selecting one goes through `selectWorkspaceNode(id:)` exactly like the former row button.
struct WorkspaceFilesSidebar: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectionDeferral = FilesSelectionDeferral()
    /// Read by body so a dropped pick re-evaluates the List binding and reverts
    /// its highlight to the tree's selection (the still-current document).
    @State private var selectionRevertTick = 0
    @State private var creationRequest: CreationRequest?
    @State private var itemName = ""
    @State private var renameTarget: WorkspaceFileNode?
    @State private var renameName = ""
    @State private var isRootExpanded = true

    var body: some View {
        Group {
            // Body dependency: this read lets a dropped pick re-read the List binding.
            // Unread @State writes do not re-evaluate body.
            let _ = selectionRevertTick
            if let tree = appState.workspaceTree {
                list(tree)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        bottomControls
                    }
            } else {
                noFolderState
            }
        }
        .alert(creationRequest?.kind.title ?? "New Item", isPresented: createAlertIsPresented) {
            TextField("Name", text: $itemName)
            Button("Create") {
                if let creationRequest {
                    create(creationRequest)
                }
                creationRequest = nil
            }
            Button("Cancel", role: .cancel) {
                creationRequest = nil
            }
        } message: {
            Text(creationRequest?.kind.prompt ?? "")
        }
        .alert("Rename “\(renameTarget?.name ?? "")”", isPresented: renameAlertIsPresented) {
            TextField("Name", text: $renameName)
            Button("Rename") {
                if let renameTarget {
                    appState.renameWorkspaceItem(id: renameTarget.id, to: renameName)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        }
        // The pick tracker is per-view @State: it outlives Files → Search → Files,
        // so a deferred open still retrying when the navigator unmounts is cancelled.
        .onDisappear { selectionDeferral.cancelPendingOpen() }
    }

    private func list(_ tree: WorkspaceFileTree) -> some View {
        List(selection: selectionBinding) {
            DisclosureGroup(isExpanded: $isRootExpanded) {
                ForEach(tree.root.children) { node in
                    WorkspaceTreeNodeRow(
                        node: node,
                        rootURL: appState.workspaceRootURL,
                        onRename: beginRename(_:),
                        onCreate: beginCreation(_:inDirectoryID:),
                        onFileClick: { selectFile(id: $0, requestingEditorFocus: true) }
                    )
                }
            } label: {
                rootLabel
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// Workspace root as the navigator's top row, like the project row in Xcode.
    private var rootLabel: some View {
        Label {
            Text(appState.workspaceRootURL?.lastPathComponent ?? "Workspace")
                .fontWeight(.semibold)
                .lineLimit(1)
        } icon: {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
        }
        .selectionDisabled()
        .help(appState.workspaceRootURL?.path(percentEncoded: false) ?? "")
        .contextMenu {
            Button("New File") {
                beginCreation(.file, inDirectoryID: nil)
            }
            Button("New Folder") {
                beginCreation(.folder, inDirectoryID: nil)
            }
            if let rootURL = appState.workspaceRootURL {
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([rootURL])
                }
            }
        }
    }

    private var noFolderState: some View {
        ContentUnavailableView {
            Label("No Folder Open", systemImage: "folder")
        } description: {
            Text("Open a folder to browse and edit its Markdown and MDX files.")
        } actions: {
            Button("Open…") {
                appState.openFile()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Glass controls floating over the bottom of the tree (Xcode navigator footer).
    private var bottomControls: some View {
        HStack {
            Menu {
                Button("New File") {
                    beginCreation(.file, inDirectoryID: selectedDirectoryID)
                }
                Button("New Folder") {
                    beginCreation(.folder, inDirectoryID: selectedDirectoryID)
                }
            } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 30, height: 30)
            .plainsongGlass(in: Circle())
            .help("Add a file or folder")

            Spacer()

            Menu {
                Picker("Show", selection: showAllFilesBinding) {
                    Text("Markdown Files Only").tag(false)
                    Text("All Files").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 30, height: 30)
            .plainsongGlass(in: Circle())
            .help(appState.showAllFiles ? "Showing all files" : "Showing Markdown files only")
            .accessibilityValue(appState.showAllFiles ? "All Files" : "Markdown Files Only")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var selectionBinding: Binding<WorkspaceFileNode.ID?> {
        Binding(
            get: { selectionDeferral.pendingID ?? appState.workspaceTree?.selectedNodeID },
            set: { newValue in
                // This setter runs inside the List/NavigationAuthority view update that
                // changed the selection, so `currentEvent` is read now while it is still
                // that event. The open itself is deferred one main-actor turn: mutating
                // AppState here publishes during the view update (R22). A left-mouse event
                // may focus the editor; key, accessibility, and a nil current event keep
                // the navigator focused. `FilesSelectionDeferral.open` retries a pick
                // refused while a workspace reload's capture lags, drops an older pick
                // that would land after a newer one, and reverts the row highlight when
                // the pick is dropped. Editor focus is requested only if the window's
                // first responder is still what it was at pick time.
                let mouseSelection = NSApp.currentEvent
                    .map { [.leftMouseDown, .leftMouseUp].contains($0.type) } ?? false
                selectFile(id: newValue, requestingEditorFocus: mouseSelection)
            }
        )
    }

    /// Native selection and filename taps can both report one click. Record it once,
    /// before starting any async work, so they share cancellation/retry/focus ownership.
    private func selectFile(id nodeID: WorkspaceFileNode.ID?, requestingEditorFocus: Bool) {
        let current = selectionDeferral.pendingID ?? appState.workspaceTree?.selectedNodeID
        // Empty space and non-file rows must not drop the open file's highlight.
        guard let nodeID else { return }
        let event = NSApp.currentEvent
        let window = event?.window ?? NSApp.keyWindow
        if nodeID == current {
            if requestingEditorFocus {
                selectionDeferral.reaffirmPendingMousePick(id: nodeID, window: window, event: event)
            }
            return
        }
        selectionDeferral.open(
            id: nodeID,
            requestingEditorFocus: requestingEditorFocus,
            pickWindow: window,
            pickEvent: event,
            appState: appState
        ) {
            selectionRevertTick += 1
        }
    }

    private var showAllFilesBinding: Binding<Bool> {
        Binding(
            get: { appState.showAllFiles },
            set: { showsAllFiles in
                if showsAllFiles != appState.showAllFiles {
                    appState.toggleShowAllFiles()
                }
            }
        )
    }

    private var createAlertIsPresented: Binding<Bool> {
        Binding(
            get: { creationRequest != nil },
            set: { isPresented in
                if !isPresented {
                    creationRequest = nil
                }
            }
        )
    }

    private var renameAlertIsPresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { isPresented in
                if !isPresented {
                    renameTarget = nil
                }
            }
        )
    }

    private var selectedDirectoryID: WorkspaceFileNode.ID? {
        guard let selectedNode = appState.workspaceTree?.selectedNode else { return nil }
        return selectedNode.isDirectory ? selectedNode.id : nil
    }

    private func beginCreation(_ kind: WorkspaceSidebarCreationKind, inDirectoryID directoryID: WorkspaceFileNode.ID?) {
        itemName = kind.defaultName
        creationRequest = CreationRequest(kind: kind, directoryID: directoryID)
    }

    private func create(_ request: CreationRequest) {
        switch request.kind {
        case .file:
            appState.createWorkspaceFile(named: itemName, inDirectoryID: request.directoryID)
        case .folder:
            appState.createWorkspaceFolder(named: itemName, inDirectoryID: request.directoryID)
        }
    }

    private func beginRename(_ node: WorkspaceFileNode) {
        renameTarget = node
        renameName = node.name
    }

    private struct CreationRequest {
        let kind: WorkspaceSidebarCreationKind
        let directoryID: WorkspaceFileNode.ID?
    }
}
