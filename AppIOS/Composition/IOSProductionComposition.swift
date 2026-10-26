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
    static func makeProduction(recoveryDirectory: URL? = nil) throws -> IOSProductionRuntime {
        let access = IOSWorkspaceAccessFactory.makeProduction()
        let recovery = try recoveryDirectory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Plainsong/Recovery", isDirectory: true)
        let documents = IOSUIDocumentStore(coordinatedAccess: access, recoveryDirectory: recovery)
        let editor = try IOSSourceEditorController(syntaxTokenizer: MarkdownSyntaxTokenizer())
        let preview = PreviewController()
        preview.installAssetReader(access)
        let controller = IOSDocumentSceneController(
            documents: documents, workspace: access, editor: editor, preview: preview,
            assets: access, admission: .process,
            assetContext: { [weak access] in access?.previewContext(for: $0) },
            openDestinationFolder: { try await access.openDestinationFolder(selectedURL: $0) }
        )
        // PreviewController already opens HTTP(S) through PreviewPlatform.
        // Its event is informational here; a second scene opener duplicates it.
        let recoveryUI = IOSRecoveryController(
            list: { await documents.recoveryList() },
            load: { try await documents.loadRecovery(recordID: $0) },
            capture: { try controller.captureRecoveryRestore($0) },
            restore: { capture, folder, isCurrent in
                try await controller.restoreRecovery(
                    capture, in: folder,
                    loadRecord: { try await documents.loadRecovery(recordID: $0) }, isCurrent: isCurrent
                )
            }
        )
        let runtime = try IOSProductionRuntime(
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
            shutdown: { [controller] in await controller.shutdown() }, recovery: recoveryUI,
            conflictCopy: IOSConflictCopyCoordinator(controller: controller)
        )
        runtime.recentPresentation.install(
            access: access,
            openRecent: { [weak controller] recordID in
                guard let controller else { throw IOSDocumentFailure.unavailable }
                try await controller.openRecent(recordID: recordID, using: access)
            },
            reselectionScope: { [weak controller] in controller?.currentGrant?.scope ?? .singleFile }
        )
        recoveryUI.onRestored = { [weak scene = runtime.scene] in scene?.navigateToDocument() }
        recoveryUI.onPresent = { [weak runtime] in runtime?.prepareForReadOnlyPresentation() }
        controller.onNavigationFailure = { [weak scene = runtime.scene] message in
            scene?.presentedError = IOSShellError(title: "Link Could Not Be Opened", message: message)
        }
        return runtime
    }

    private init() {}
}
