import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceKit

/// What a Files row can do. Built by the navigator, so rows read no `AppState` themselves.
struct WorkspaceTreeRowActions {
    let setExpanded: (Bool, WorkspaceFileNode.ID) -> Void
    let rename: (WorkspaceFileNode) -> Void
    let create: (WorkspaceSidebarCreationKind, WorkspaceFileNode.ID?) -> Void
    let fileClick: (WorkspaceFileNode.ID) -> Void
    let trash: (WorkspaceFileNode.ID) -> Void
    /// Moves the dropped item (first ID) into the directory (second ID).
    let move: @MainActor @Sendable (WorkspaceFileNode.ID, WorkspaceFileNode.ID) -> Void
}

/// One Files row and, for a directory, its subtree.
///
/// Rows take the tree's values instead of observing `AppState`: an environment object made
/// every row re-render on each AppState change (a typing pause, a statistics refresh). As an
/// `Equatable` view a row re-renders only when its subtree, its expansion state, or the
/// root changes; `actions` are stable behavior and are not compared.
struct WorkspaceTreeNodeRow: View, Equatable {
    let node: WorkspaceFileNode
    let rootURL: URL?
    let expandedNodeIDs: Set<WorkspaceFileNode.ID>
    let actions: WorkspaceTreeRowActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node == rhs.node
            && lhs.rootURL == rhs.rootURL
            && lhs.expandedNodeIDs == rhs.expandedNodeIDs
    }

    /// A file row skips re-rendering through `.equatable()`. A directory row stays a bare
    /// `DisclosureGroup`: `List` draws an outline row with a disclosure triangle only for a
    /// `DisclosureGroup` it sees directly, not one inside an `EquatableView`.
    @ViewBuilder
    static func row(
        node: WorkspaceFileNode,
        rootURL: URL?,
        expandedNodeIDs: Set<WorkspaceFileNode.ID>,
        actions: WorkspaceTreeRowActions
    ) -> some View {
        let row = WorkspaceTreeNodeRow(node: node, rootURL: rootURL, expandedNodeIDs: expandedNodeIDs, actions: actions)
        if node.isDirectory {
            row
        } else {
            row.equatable()
        }
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expandedBinding) {
                ForEach(node.children) { child in
                    Self.row(node: child, rootURL: rootURL, expandedNodeIDs: expandedNodeIDs, actions: actions)
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
        // On macOS 15 the drag hit view can consume a filename click before the
        // List's selection binding sees it. A completed tap joins the same deferred
        // selection path; dragging still uses the native provider above.
        .simultaneousGesture(node.isEditableMarkdown ? TapGesture().onEnded {
            actions.fileClick(node.id)
        } : nil)
        .accessibilityIdentifier("plainsong.workspaceFiles.row.\(node.relativePath)")
        .help(node.relativePath)
        .contextMenu {
            if node.isDirectory {
                Button("New File") {
                    actions.create(.file, node.id)
                }
                Button("New Folder") {
                    actions.create(.folder, node.id)
                }
                Divider()
            }

            Button("Rename…") {
                actions.rename(node)
            }

            if let itemURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([itemURL])
                }
            }

            Divider()

            Button("Move to Trash", role: .destructive) {
                actions.trash(node.id)
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
        let isExpanded = expandedNodeIDs.contains(node.id)
        return Binding(
            get: { isExpanded },
            set: { [actions, nodeID = node.id] isExpanded in
                actions.setExpanded(isExpanded, nodeID)
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

        let move = actions.move
        let directoryID = node.id
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let droppedID: String? = if let data = item as? Data {
                String(data: data, encoding: .utf8)
            } else {
                item as? String
            }

            guard let droppedID, droppedID != directoryID else { return }
            Task { @MainActor in
                move(droppedID, directoryID)
            }
        }

        return true
    }
}
