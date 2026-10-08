import Foundation
import MarkdownCore

public enum IOSPreviewEvent: Sendable {
    case ready
    case renderCompleted(documentID: IOSDocumentIdentity, renderID: Int, version: Int)
    case relativeLinkRequested(documentID: IOSDocumentIdentity, href: String)
    case externalLinkRequested(URL)
    case checkboxRequested(revision: IOSDocumentRevision, renderID: Int, line: Int, checked: Bool)
    case failed(PreviewAssetReadFailure)
}

/// No view type in the contract. 07 owns the retained UIKit/WebKit host.
/// A nil assetAccess disables sibling reads for a single-file grant.
@MainActor
public protocol IOSPreviewControlling: AnyObject {
    func render(_ snapshot: DocumentSnapshot, identity: IOSDocumentIdentity, assetAccess: PreviewAssetAccessContext?)
    func setRemoteImagesAllowed(_ allowed: Bool)
    func scrollToLine(_ line: Int)
    func invalidate()
    func observe(_ handler: @escaping @MainActor (IOSPreviewEvent) -> Void) -> any IOSObservation
}
