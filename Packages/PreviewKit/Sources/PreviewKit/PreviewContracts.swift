import Foundation
import MarkdownCore

public enum IOSPreviewEvent: Sendable {
    case ready
    case renderCompleted(documentID: IOSDocumentIdentity, renderID: Int, version: Int)
    case relativeLinkRequested(documentID: IOSDocumentIdentity, href: String)
    case externalLinkRequested(URL)
    case checkboxRequested(revision: IOSDocumentRevision, renderID: Int, line: Int, checked: Bool)
    case failed(PreviewAssetReadFailure)
    /// The blocking content rule did not compile. The preview page stays unloaded.
    case contentRuleUnavailable
}

/// Shown when the preview cannot install a network block and therefore refuses to load.
public enum PreviewNetworkPolicyFailure {
    public static let userMessage =
        "The preview did not load because its network policy could not be prepared. Remote content stays blocked."
}

/// No view type in the contract.
/// A nil assetAccess disables sibling reads for a single-file grant.
@MainActor
public protocol IOSPreviewControlling: AnyObject {
    func render(_ snapshot: DocumentSnapshot, identity: IOSDocumentIdentity, assetAccess: PreviewAssetAccessContext?)
    func setRemoteImagesAllowed(_ allowed: Bool)
    func scrollToLine(_ line: Int)
    func invalidate()
    func observe(_ handler: @escaping @MainActor (IOSPreviewEvent) -> Void) -> any IOSObservation
}
