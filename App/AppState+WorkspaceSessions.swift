import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func canonicalSessionURL(for url: URL) throws -> URL {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if let workspaceRootURL {
            _ = try WorkspaceRootContainment.relativePath(
                for: resolvedURL,
                rootURL: workspaceRootURL
            )
        }
        return resolvedURL
    }

    func synchronizeWorkspaceTreeSelection(for session: DocumentSession) {
        guard let rootURL = workspaceRootURL,
              let fileURL = session.fileURL,
              let relativePath = try? WorkspaceRootContainment.relativePath(
                  for: fileURL,
                  rootURL: rootURL
              ),
              var tree = workspaceTree,
              let node = firstNode(
                  in: tree.root,
                  canonicalRelativePath: relativePath,
                  rootURL: rootURL
              )
        else {
            return
        }

        tree.selectNode(id: node.id)
        workspaceTree = tree
    }

    func handleSessionEvictions(_ evictions: [WorkspaceSessionEviction]) {
        for eviction in evictions {
            guard let session = sessionCache[eviction.url] else { continue }
            finishSessionEviction(eviction, session: session)
        }
    }

    func reconcileSessionPolicyAfterEditorLeaseChange() {
        handleSessionEvictions(sessionPolicy.trim(protectedURLs: protectedSessionURLs()))
    }

    func protectedSessionURLs() -> Set<URL> {
        var urls: Set<URL> = []
        if let currentURL = currentDocument.fileURL?.standardizedFileURL.resolvingSymlinksInPath() {
            urls.insert(currentURL)
        }
        if let installedURL = installedEditorDocumentBindingLease?.session.fileURL?
            .standardizedFileURL.resolvingSymlinksInPath()
        {
            urls.insert(installedURL)
        }
        return urls
    }

    func nodeForCurrentDocument(in tree: WorkspaceFileTree, root: URL) -> WorkspaceFileNode? {
        guard let currentURL = currentDocument.fileURL?.standardizedFileURL,
              Self.isDescendant(currentURL, of: root),
              let relativePath = Self.workspaceRelativePath(for: currentURL, root: root)
        else {
            return nil
        }

        return firstNode(
            in: tree.root,
            canonicalRelativePath: relativePath,
            rootURL: root
        )
    }

    func firstNode(
        in node: WorkspaceFileNode,
        canonicalRelativePath: String,
        rootURL: URL
    ) -> WorkspaceFileNode? {
        if let exactNode = firstNode(in: node, relativePath: canonicalRelativePath) {
            return exactNode
        }
        return firstNodeResolvingAlias(
            in: node,
            canonicalRelativePath: canonicalRelativePath,
            rootURL: rootURL
        )
    }

    func firstNode(in node: WorkspaceFileNode, relativePath: String) -> WorkspaceFileNode? {
        if ExactSourceText.matches(node.relativePath, relativePath) {
            return node
        }

        for child in node.children {
            if let match = firstNode(in: child, relativePath: relativePath) {
                return match
            }
        }
        return nil
    }

    private func finishSessionEviction(
        _ eviction: WorkspaceSessionEviction,
        session: DocumentSession
    ) {
        if eviction.requiresSave {
            do {
                try save(session: session)
            } catch {
                present(error, title: "Could Not Save Warm File")
                var protectedURLs = protectedSessionURLs()
                protectedURLs.insert(eviction.url)
                handleSessionEvictions(sessionPolicy.access(
                    eviction.url,
                    isDirty: session.isDirty,
                    protectedURLs: protectedURLs
                ))
                return
            }
        }
        cancelAutosave(for: session)
        sessionCache[eviction.url] = nil
        removeEditorDocumentBindingRegistration(for: session)
    }

    private func firstNodeResolvingAlias(
        in node: WorkspaceFileNode,
        canonicalRelativePath: String,
        rootURL: URL
    ) -> WorkspaceFileNode? {
        if node.isEditableMarkdown,
           let nodeURL = try? WorkspaceRootContainment.containedURL(
               rootURL: rootURL,
               relativePath: node.relativePath
           ),
           let nodePath = try? WorkspaceRootContainment.relativePath(
               for: nodeURL,
               rootURL: rootURL
           ),
           ExactSourceText.matches(nodePath, canonicalRelativePath)
        {
            return node
        }

        for child in node.children {
            if let match = firstNodeResolvingAlias(
                in: child,
                canonicalRelativePath: canonicalRelativePath,
                rootURL: rootURL
            ) {
                return match
            }
        }
        return nil
    }
}
