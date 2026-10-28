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
        let style: UIUserInterfaceStyle = switch preferences.editorAppearance {
        case .system:
            colorScheme == .dark ? .dark : .light
        case .light:
            .light
        case .dark:
            .dark
        }
        let theme = IOSEditorTheme.reading(
            appearance: style,
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
        let assetRoot: URL = if let grant = sceneController?.currentGrant, grant.scope == .directory {
            grant.rootURL
        } else {
            stored.location.fileURL.deletingLastPathComponent()
        }
        let source = DocumentTextChange(
            text: document.text,
            version: document.version,
            fileKind: document.fileKind,
            fileURL: stored.location.fileURL
        )
        exporter.onFailure = { [weak scene] message in
            scene?.presentedError = IOSShellError(title: "Couldn't Export", message: message)
        }
        exporter.onNote = { [weak scene] message in
            scene?.presentedError = IOSShellError(title: "Exported with Changes", message: message)
        }
        exporter.begin(
            kind,
            source: source,
            assetRoot: assetRoot,
            theme: previewThemeName,
            assetReader: sceneController?.workspace as? IOSWorkspaceAccessService
        )
    }
}
