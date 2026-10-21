import EditorKitIOS
import PreviewKitContracts
import WorkspaceKitIOS

/// C0 cannot construct a production provider. M0 and real providers are open gates.
/// Phase B may replace `c0` only after the ledger's owner rows are checked, and
/// only after `IOSOpenDocumentAdmission` has accepted that scene's one writer.
/// The app entry does not call the admission, and this value installs nothing.
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

    private init() {}
}
