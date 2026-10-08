import EditorKitIOS
import PreviewKitContracts
import WorkspaceKitIOS

/// C0 cannot construct a production provider. M0 and real providers are open gates.
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
