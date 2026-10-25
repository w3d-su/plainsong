import EditorKitIOS
import Foundation
import MarkdownCore
import PreviewKitContracts
import SwiftUI
import UIKit
import WorkspaceCore
import WorkspaceKitIOS

/// Sheets the shell can present. Content comes from 08/09 hosted views (or a
/// placeholder while those providers are unavailable). Dismissal is never a commit.
enum IOSShellPresentation: Hashable, Identifiable {
    case frontmatter
    case findReplace
    case imagePicker

    var id: Self {
        self
    }
}

/// Which 08-hosted panel a sheet should contain.
enum IOSShellAuthoringPanel: Hashable {
    case frontmatter
    case findReplace
}

/// Context handed to hosted sheet content factories (08/09) at presentation time.
/// The hosted view registers `onDismiss` for cancel semantics; the shell invokes
/// it exactly once per dismissal and never signals a commit on the content's behalf.
@MainActor
final class IOSShellSheetContext {
    let facade: any IOSAppSceneControlling
    let editor: (any IOSSourceEditorControlling)?
    let presentation: IOSShellPresentation
    /// For the image flow: the open Markdown document. The writer persists
    /// assets beside that document. The hosted picker passes this location
    /// to `IOSImageInsertionControlling.captureContext`.
    let destination: IOSFileLocation?
    /// For the image flow: the workspace grant captured at presentation time
    /// (surfaces.currentGrant). Nil disables the insert path inside the sheet.
    let grant: IOSWorkspaceGrant?

    private var dismissHandlers: [() -> Void] = []

    init(
        facade: any IOSAppSceneControlling,
        editor: (any IOSSourceEditorControlling)?,
        presentation: IOSShellPresentation,
        destination: IOSFileLocation? = nil,
        grant: IOSWorkspaceGrant? = nil
    ) {
        self.facade = facade
        self.editor = editor
        self.presentation = presentation
        self.destination = destination
        self.grant = grant
    }

    /// The hosted content registers its cancel/rollback notification here.
    /// Called exactly once when the sheet goes away for any reason.
    func onDismiss(_ handler: @escaping () -> Void) {
        dismissHandlers.append(handler)
    }

    func notifyDismissed() {
        let handlers = dismissHandlers
        dismissHandlers = []
        for handler in handlers {
            handler()
        }
    }
}

/// Provider seams the shell needs but C0 does not freeze into
/// `IOSSceneCapabilities`: feature surfaces (08/09) and the native hosted views
/// whose concrete types belong to 04/07. Production wiring fills these in
/// `AppIOS/Composition` (13); tests fill them with doubles. A nil surface means
/// the capability is genuinely unavailable — the shell disables the UI instead
/// of fabricating it.
@MainActor
struct IOSShellFeatureSurfaces {
    /// 08's descriptors/handlers (`IOSAuthoringActionProviding`).
    var authoring: (any IOSAuthoringActionProviding)?

    /// 09's image insertion flow (`IOSImageInsertionControlling`).
    var imageInsertion: (any IOSImageInsertionControlling)?

    /// Hosted view factories. Each is invoked at most once per capability
    /// instance; the returned view is retained by the scene for its lifetime so
    /// layout mode changes never recreate or detach the native editor/preview.
    var makeEditorView: ((any IOSSourceEditorBinding) -> UIView?)?
    var makePreviewView: ((any IOSPreviewControlling) -> UIView?)?

    /// Hosted sheet content: 08's frontmatter/find panels and 09's picker.
    var makeAuthoringPanel: ((IOSShellAuthoringPanel, IOSShellSheetContext) -> AnyView?)?
    var makeImagePicker: ((IOSShellSheetContext) -> AnyView?)?

    /// New-file root and image insertion need the access provider's current
    /// grant; a scene snapshot or derived parent is never an implicit grant.
    var currentGrant: (() -> IOSWorkspaceGrant?)?

    /// Conflict "Save a Copy" needs a destination picker + lease owned by
    /// composition; nil hides that button (W14).
    var resolveConflictCopy: (() -> Void)?

    /// Workspace refresh requires the live grant; composition routes it (W15).
    var refreshWorkspace: (() -> Void)?

    /// "Open file/folder" needs a UIDocumentPicker grant that must originate
    /// from user selection; composition owns the picker (W16). Nil hides Open.
    var openWorkspace: (() -> Void)?

    /// Recent rows carry opaque record IDs; the scene's existing access service
    /// alone restores bookmarks. Composition owns the list and picker handoff.
    var showRecentWorkspaces: (() -> Void)?

    /// Unavailable access requires explicit file/folder reselection, preserving
    /// the recorded scope. This callback does not reload or replace source.
    var reselectUnavailableWorkspace: (() -> Void)?
}
