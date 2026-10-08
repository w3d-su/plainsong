import Foundation
import WorkspaceCore

/// Builds the Mac tree through WorkspaceCore, then puts each physical proof back.
///
/// The sidecar index is the snapshot's entry position. Path strings are not the
/// lookup key: canonically equivalent spellings keep distinct proofs.
enum WorkspaceCoreAdapter {
    static func reconcile(
        previous: WorkspaceFileTree?,
        snapshot: WorkspaceFileSnapshot,
        options: WorkspaceFileTree.Options
    ) -> WorkspaceFileTree {
        let expectations = snapshot.entries.map(\.mutationExpectation)
        let pure = WorkspacePureTree.reconcile(
            previousExpandedNodeIDs: previous?.expandedNodeIDs ?? [],
            previousSelectedNodeID: previous?.selectedNodeID,
            entries: snapshot.entries.enumerated().map { index, entry in
                WorkspacePureEntry(
                    relativePath: entry.relativePath,
                    kind: entry.kind,
                    identity: entry.identity,
                    contentModificationDate: entry.contentModificationDate,
                    sidecarIndex: index
                )
            },
            options: WorkspacePureTree.Options(showAllFiles: options.showAllFiles)
        )
        return WorkspaceFileTree(
            root: macNode(pure.root, expectations: expectations),
            expandedNodeIDs: pure.expandedNodeIDs,
            selectedNodeID: pure.selectedNodeID
        )
    }

    private static func macNode(
        _ node: WorkspacePureNode,
        expectations: [WorkspaceItemMutationExpectation?]
    ) -> WorkspaceFileNode {
        WorkspaceFileNode(
            id: node.id,
            name: node.name,
            relativePath: node.relativePath,
            kind: node.kind,
            contentModificationDate: node.contentModificationDate,
            mutationExpectation: mutationExpectation(for: node, expectations: expectations),
            children: node.children.map { macNode($0, expectations: expectations) }
        )
    }

    private static func mutationExpectation(
        for node: WorkspacePureNode,
        expectations: [WorkspaceItemMutationExpectation?]
    ) -> WorkspaceItemMutationExpectation? {
        guard expectations.indices.contains(node.sidecarIndex) else { return nil }
        return expectations[node.sidecarIndex]
    }
}
