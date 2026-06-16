import SwiftUI
import UniformTypeIdentifiers
import WorkspaceKit

struct WorkspaceSidebar: View {
    @EnvironmentObject private var appState: AppState
    @State private var creationMode: CreationMode?
    @State private var itemName = ""
    @State private var renameTarget: WorkspaceFileNode?
    @State private var renameName = ""

    var body: some View {
        List {
            if let tree = appState.workspaceTree {
                Section {
                    Toggle("Show All Files", isOn: showAllFilesBinding)
                    HStack(spacing: 8) {
                        Button {
                            itemName = "Untitled.md"
                            creationMode = .file
                        } label: {
                            Label("New File", systemImage: "doc.badge.plus")
                        }
                        .labelStyle(.iconOnly)
                        .help("New File")

                        Button {
                            itemName = "New Folder"
                            creationMode = .folder
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        .labelStyle(.iconOnly)
                        .help("New Folder")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text(appState.workspaceRootURL?.lastPathComponent ?? "Workspace")
                }

                Section {
                    ForEach(tree.root.children) { node in
                        WorkspaceTreeNodeRow(
                            node: node,
                            selectedNodeID: tree.selectedNodeID,
                            onRename: beginRename(_:)
                        )
                    }
                }
            } else {
                Section("Workspace") {
                    Label("No folder open", systemImage: "sidebar.left")
                        .foregroundStyle(.secondary)
                }
            }

            Section("File") {
                if let fileURL = appState.currentDocument.fileURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileURL.lastPathComponent)
                            .lineLimit(1)
                        Text(fileURL.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                } else {
                    Text("No file open")
                        .foregroundStyle(.secondary)
                }
            }

            if appState.hasOpenDocument {
                Section {
                    let session = appState.currentDocument
                    FrontmatterPanel(session: session) { newText in
                        appState.replaceDocumentText(newText, in: session)
                    }
                }
            }
        }
        .alert("Create Item", isPresented: createAlertIsPresented) {
            TextField("Name", text: $itemName)
            Button("Create") {
                switch creationMode {
                case .file:
                    appState.createWorkspaceFile(named: itemName, inDirectoryID: selectedDirectoryID)
                case .folder:
                    appState.createWorkspaceFolder(named: itemName, inDirectoryID: selectedDirectoryID)
                case .none:
                    break
                }
                creationMode = nil
            }
            Button("Cancel", role: .cancel) {
                creationMode = nil
            }
        }
        .alert("Rename", isPresented: renameAlertIsPresented) {
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

    private var showAllFilesBinding: Binding<Bool> {
        Binding(
            get: { appState.showAllFiles },
            set: { _ in appState.toggleShowAllFiles() }
        )
    }

    private var createAlertIsPresented: Binding<Bool> {
        Binding(
            get: { creationMode != nil },
            set: { isPresented in
                if !isPresented {
                    creationMode = nil
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

    private func beginRename(_ node: WorkspaceFileNode) {
        renameTarget = node
        renameName = node.name
    }

    private enum CreationMode {
        case file
        case folder
    }
}

private struct WorkspaceTreeNodeRow: View {
    @EnvironmentObject private var appState: AppState

    let node: WorkspaceFileNode
    let selectedNodeID: WorkspaceFileNode.ID?
    let onRename: (WorkspaceFileNode) -> Void

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expandedBinding) {
                ForEach(node.children) { child in
                    WorkspaceTreeNodeRow(
                        node: child,
                        selectedNodeID: selectedNodeID,
                        onRename: onRename
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
        Button {
            if node.isEditableMarkdown {
                appState.selectWorkspaceNode(id: node.id)
            }
        } label: {
            Label(node.name, systemImage: iconName)
                .lineLimit(1)
                .foregroundStyle(node.isEditableMarkdown ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selectedNodeID == node.id ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .draggable(node.id)
        .contextMenu {
            Button("Rename") {
                onRename(node)
            }

            Button("Move to Trash", role: .destructive) {
                appState.trashWorkspaceItem(id: node.id)
            }
        }
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
