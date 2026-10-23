import EditorKitIOS
import Foundation
import MarkdownCore
import PreviewKitContracts
import WorkspaceCore
import WorkspaceKitIOS

@MainActor
struct IOSSceneCapabilities {
    let editor: (any IOSSourceEditorBinding)?
    let documents: (any IOSDocumentStore)?
    let workspace: (any IOSWorkspaceAccessProviding)?
    let preview: (any IOSPreviewControlling)?
    let assets: (any IOSWorkspaceAssetWriting)?
}

struct IOSAppSceneSnapshot: Sendable {
    let document: IOSStoredDocumentSnapshot?
    let documentState: IOSDocumentState?
    let workspace: IOSWorkspaceSnapshot?
    let unavailableReason: String?
}

/// The 10 shell consumes this facade. Only 13 supplies its production implementation.
/// Observers receive immutable state; no shadow editable String or global writer.
@MainActor
protocol IOSAppSceneControlling: AnyObject {
    var snapshot: IOSAppSceneSnapshot { get }
    var capabilities: IOSSceneCapabilities { get }
    func setCommandFocus(_ focused: Bool, expected: IOSDocumentIdentity, bindingID: UUID) -> Bool
    func openSelectedURL(_ url: URL, scope: IOSWorkspaceScope) async throws
    func createDocument(at location: IOSFileLocation) async throws
    func saveCurrentDocument() async throws -> IOSSaveAcknowledgement
    func resolveExternal(_ choice: IOSExternalResolution) async throws
    func observe(_ handler: @escaping @MainActor (IOSAppSceneSnapshot) -> Void) -> any IOSObservation
    func flushForBackground() async -> [IOSDocumentFlushOutcome]
}
