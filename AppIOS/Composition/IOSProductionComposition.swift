import EditorKitIOS
import Foundation
import PreviewKit
import PreviewKitContracts
import SyntaxKit
import UIKit
import WorkspaceKitIOS

/// C0 remains an unavailable sentinel for contract regressions. The production
/// factory composes the existing providers after the recorded M0 admission.
@MainActor
struct IOSProductionComposition {
    static var c0: IOSProductionComposition {
        IOSProductionComposition()
    }

    let capabilities = IOSSceneCapabilities(
        editor: nil,
        documents: nil,
        workspace: nil,
        preview: nil,
        assets: nil
    )
    let unavailableMessage = "Development scaffold. Editing and file access await device validation and providers."

    /// The real providers share one access service and one UIDocument-backed store.
    /// M0 owner prerequisites and candidate readiness are recorded in the ledger.
    static func makeProduction() throws -> IOSProductionRuntime {
        let access = IOSWorkspaceAccessFactory.makeProduction()
        let recovery = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Plainsong/Recovery", isDirectory: true)
        let documents = IOSUIDocumentStore(coordinatedAccess: access, recoveryDirectory: recovery)
        let editor = try IOSSourceEditorController(syntaxTokenizer: MarkdownSyntaxTokenizer())
        let preview = PreviewController()
        preview.installAssetReader(access)
        let controller = IOSDocumentSceneController(
            documents: documents, workspace: access, editor: editor, preview: preview,
            assets: access, admission: .process, assetContext: { [weak access] in access?.previewContext(for: $0) }
        )
        controller.openExternalURL = { UIApplication.shared.open($0) }
        return try IOSProductionRuntime(
            controller: controller, editor: editor, preview: preview,
            currentGrant: { [weak controller] in
                guard controller?.grantIsCurrent == true else { return nil }
                return controller?.currentGrant
            },
            refreshWorkspace: { [weak controller] in
                guard let controller else { throw IOSDocumentFailure.unavailable }
                try await controller.refreshWorkspace()
            },
            openPickedURL: { [weak controller] url, scope in
                guard let controller else { throw IOSDocumentFailure.unavailable }
                try await controller.openPickedURL(url, scope: scope)
            },
            shutdown: { [controller] in await controller.shutdown() }
        )
    }

    private init() {}
}
