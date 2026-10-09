import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceKit

/// Files navigator: workspace tree with glass Add/Filter controls (WS3C Files mode).
///
/// The tree is a native source list: selection, keyboard navigation, and the inactive-window
/// highlight come from `List(selection:)`. Only editable Markdown rows are selectable, and
/// selecting one goes through `selectWorkspaceNode(id:)` exactly like the former row button.
struct WorkspaceFilesSidebar: View {
    @EnvironmentObject private var appState: AppState
    @State private var creationRequest: CreationRequest?
    @State private var itemName = ""
    @State private var renameTarget: WorkspaceFileNode?
    @State private var renameName = ""
    @State private var isRootExpanded = true

    var body: some View {
        Group {
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
    }

    private func list(_ tree: WorkspaceFileTree) -> some View {
        List(selection: selectionBinding) {
            DisclosureGroup(isExpanded: $isRootExpanded) {
                ForEach(tree.root.children) { node in
                    WorkspaceTreeNodeRow(
                        node: node,
                        rootURL: appState.workspaceRootURL,
                        onRename: beginRename(_:),
                        onCreate: beginCreation(_:inDirectoryID:)
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
            get: { appState.workspaceTree?.selectedNodeID },
            set: { newValue in
                // Clicking empty space or a non-file row must not drop the open file's highlight.
                guard let newValue, newValue != appState.workspaceTree?.selectedNodeID else { return }
                // List retains its native selection/drag gestures. This setter runs
                // synchronously inside the event that changed the selection, so
                // `currentEvent` is still that event; SwiftUI does not defer the binding
                // to a later turn. A left-mouse event may focus the editor. Key,
                // accessibility, and a nil current event keep the navigator focused.
                let mouseSelection = NSApp.currentEvent
                    .map { [.leftMouseDown, .leftMouseUp].contains($0.type) } ?? false
                appState.selectWorkspaceNode(id: newValue, requestingEditorFocus: mouseSelection)
            }
        )
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

struct WorkspaceTreeNodeRow: View {
    @EnvironmentObject private var appState: AppState

    let node: WorkspaceFileNode
    let rootURL: URL?
    let onRename: (WorkspaceFileNode) -> Void
    let onCreate: (WorkspaceSidebarCreationKind, WorkspaceFileNode.ID?) -> Void

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expandedBinding) {
                ForEach(node.children) { child in
                    WorkspaceTreeNodeRow(
                        node: child,
                        rootURL: rootURL,
                        onRename: onRename,
                        onCreate: onCreate
                    )
                }
            } label: {
                rowLabel
            }
            .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                handleDrop(providers)
            }
        } else {
            rowLabel
        }
    }

    private var rowLabel: some View {
        Label {
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: iconName)
        }
        .foregroundStyle(isDimmed ? .secondary : .primary)
        .tag(node.id)
        .selectionDisabled(!node.isEditableMarkdown)
        .onDrag {
            WorkspaceSidebarDragProvider.make(nodeID: node.id, imageURL: imageURL)
        }
        .help(node.relativePath)
        .contextMenu {
            if node.isDirectory {
                Button("New File") {
                    onCreate(.file, node.id)
                }
                Button("New Folder") {
                    onCreate(.folder, node.id)
                }
                Divider()
            }

            Button("Rename…") {
                onRename(node)
            }

            if let itemURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([itemURL])
                }
            }

            Divider()

            Button("Move to Trash", role: .destructive) {
                appState.trashWorkspaceItem(id: node.id)
            }
        }
    }

    private var isDimmed: Bool {
        !node.isDirectory && !node.isEditableMarkdown
    }

    private var imageURL: URL? {
        guard case .image = node.kind else { return nil }
        return itemURL
    }

    private var itemURL: URL? {
        rootURL?.appending(path: node.relativePath, directoryHint: node.isDirectory ? .isDirectory : .notDirectory)
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { appState.workspaceTree?.isExpanded(node.id) == true },
            set: { isExpanded in
                appState.setWorkspaceNodeExpanded(isExpanded, id: node.id)
            }
        )
    }

    private var iconName: String {
        switch node.kind {
        case .directory:
            "folder"
        case .markdown, .mdx:
            "doc.text"
        case .image:
            "photo"
        case .other:
            "doc"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard node.isDirectory,
              let provider = providers
              .first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) })
        else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let droppedID: String? = if let data = item as? Data {
                String(data: data, encoding: .utf8)
            } else {
                item as? String
            }

            guard let droppedID, droppedID != node.id else { return }
            Task { @MainActor in
                appState.moveWorkspaceItem(id: droppedID, toDirectoryID: node.id)
            }
        }

        return true
    }
}
