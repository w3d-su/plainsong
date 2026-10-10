import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceKit

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
