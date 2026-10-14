import AppKit

/// Keep the node-ID representation for workspace moves, and expose file URLs for the
/// editor's existing image drop path. A String-only drag cannot reach imageFileURLs.
enum WorkspaceSidebarDragProvider {
    static func make(nodeID: String, imageURL: URL?) -> NSItemProvider {
        let provider = NSItemProvider(object: nodeID as NSString)
        if let imageURL {
            provider.registerObject(imageURL as NSURL, visibility: .all)
        }
        return provider
    }
}
