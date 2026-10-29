import EditorKitIOS
import Foundation
import MarkdownCore
import PreviewKit
import SwiftUI
import UIKit
import WorkspaceKitIOS

extension IOSProductionRuntime {
    func apply(_ preferences: IOSAppPreferences, colorScheme: ColorScheme) {
        previewThemeName = preferences.previewAppearance.rawValue
        systemAppearanceIsDark = colorScheme == .dark
        // System follows the environment. Light and dark force the editor's
        // traits so dynamic system colors cannot inherit the opposite appearance.
        let interfaceStyle: UIUserInterfaceStyle
        let themeStyle: UIUserInterfaceStyle
        switch preferences.editorAppearance {
        case .system:
            interfaceStyle = .unspecified
            themeStyle = colorScheme == .dark ? .dark : .light
        case .light:
            interfaceStyle = .light
            themeStyle = .light
        case .dark:
            interfaceStyle = .dark
            themeStyle = .dark
        }
        editor.applyInterfaceStyle(interfaceStyle)
        let theme = IOSEditorTheme.reading(
            appearance: themeStyle,
            pointSize: CGFloat(preferences.editorFontSize),
            fontName: preferences.editorFontName,
            palette: preferences.editorPalette
        )
        if editor.theme != theme {
            editor.theme = theme
        }
        if editor.showsLineNumbers != preferences.showsLineNumbers {
            editor.showsLineNumbers = preferences.showsLineNumbers
        }
        typewriterRequested = preferences.typewriterSyncEnabled
        applyTypewriter(layout: scene.layout)
        preview.setTheme(preferences.previewAppearance.rawValue)
        preview.setAllowsRemoteImages(preferences.allowsRemoteImages)
        if let sceneController = controller as? IOSDocumentSceneController {
            sceneController.preferredNewDocumentExtension = preferences.newFileExtension.rawValue
            if let store = sceneController.documents as? IOSUIDocumentStore {
                store.timing = IOSDocumentTiming(
                    autosaveDelayNanoseconds: preferences.autosaveDelayNanoseconds,
                    backgroundFlushNanoseconds: store.timing.backgroundFlushNanoseconds
                )
            }
            if let access = sceneController.workspace as? IOSWorkspaceAccessService {
                access.setAssetDirectoryName(preferences.assetDirectoryName)
            }
        }
    }

    func beginExport(_ kind: IOSDocumentExportKind) {
        guard !exporter.isRunning else { return }
        guard let stored = controller.snapshot.document else {
            scene.presentedError = IOSShellError(
                title: "Couldn't Export", message: "Open a document before exporting."
            )
            return
        }
        let editorSnapshot = editor.captureSnapshot()
        let useEditor = editorSnapshot?.revision.documentID == stored.revision.documentID
        let document = useEditor ? editorSnapshot?.document : stored.document
        guard let document else {
            scene.presentedError = IOSShellError(
                title: "Couldn't Export", message: "The document is not ready to export."
            )
            return
        }
        let sceneController = controller as? IOSDocumentSceneController
        // The live preview's authority: a current directory grant, read through its
        // lease. A single-file grant never promotes the file's parent folder.
        let assetAccess: PreviewAssetAccessContext? = sceneController.flatMap { scene in
            guard scene.grantIsCurrent, let grant = scene.currentGrant, grant.scope == .directory else {
                return nil
            }
            return scene.assetContext(grant)
        }
        let source = DocumentTextChange(
            text: document.text,
            version: document.version,
            fileKind: document.fileKind,
            fileURL: stored.location.fileURL
        )
        let documentID = stored.revision.documentID
        exporter.onFailure = { [weak scene] message in
            scene?.presentedError = IOSShellError(title: "Couldn't Export", message: message)
        }
        exporter.onNote = { [weak scene] message in
            scene?.presentedError = IOSShellError(title: "Exported with Changes", message: message)
        }
        exporter.begin(
            kind,
            source: source,
            assetAccess: assetAccess,
            theme: IOSExportTheme.resolve(
                kind: kind,
                preference: previewThemeName,
                systemIsDark: systemAppearanceIsDark
            ),
            assetReader: sceneController?.workspace as? IOSWorkspaceAccessService,
            isCurrent: { [weak self] in
                self?.controller.snapshot.document?.revision.documentID == documentID
            }
        )
    }
}
