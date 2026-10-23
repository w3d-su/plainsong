import EditorKitIOS
import Foundation
import MarkdownCore
import PreviewKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WorkspaceKitIOS

/// A picker issuance carries its explicit authority; a stale completion cannot
/// turn a file selection into a directory grant or reopen a later picker.
struct IOSProductionPickerRequest: Identifiable {
    let id = UUID()
    let scope: IOSWorkspaceScope

    var contentTypes: [UTType] {
        if scope == .directory {
            return [.folder]
        }
        return [.plainText, UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "mdx") ?? .plainText]
    }
}

/// Retained by the scene's StateObject. The existing shell and feature modules
/// consume the same facade/editor; only the facade may grant or write documents.
@MainActor
final class IOSProductionRuntime: ObservableObject {
    let controller: any IOSAppSceneControlling
    let editor: IOSSourceEditorController
    let preview: PreviewController
    let scene: IOSShellSceneState
    let authoring = IOSAuthoringController()
    let images: IOSImageInsertionController

    @Published var showOpenChoices = false
    @Published var pickerRequest: IOSProductionPickerRequest?
    @Published private(set) var isOpening = false

    private let currentGrant: () -> IOSWorkspaceGrant?
    private let refreshWorkspace: @MainActor () async throws -> Void
    private let openPickedURL: @MainActor (URL, IOSWorkspaceScope) async throws -> Void
    private var hostedContextID: ObjectIdentifier?
    private var hostedSheet: AnyView?
    private var editorObservation: (any IOSObservation)?
    private var observedBindingID: UUID?
    private var isSceneActive = true
    private var inactiveFocus: (identity: IOSDocumentIdentity, bindingID: UUID)?

    init(
        controller: any IOSAppSceneControlling,
        editor: IOSSourceEditorController,
        preview: PreviewController,
        currentGrant: @escaping () -> IOSWorkspaceGrant?,
        refreshWorkspace: @escaping @MainActor () async throws -> Void,
        openPickedURL: @escaping @MainActor (URL, IOSWorkspaceScope) async throws -> Void
    ) throws {
        guard let assets = controller.capabilities.assets else {
            throw IOSDocumentFailure.unavailable
        }
        self.controller = controller
        self.editor = editor
        self.preview = preview
        self.currentGrant = currentGrant
        self.refreshWorkspace = refreshWorkspace
        self.openPickedURL = openPickedURL
        images = IOSImageInsertionController(writer: assets)
        scene = IOSShellSceneState(facade: controller)
        installSurfaces()
    }

    func startObserving() {
        guard editorObservation == nil else { return }
        let currentBinding = editor.captureSnapshot()?.bindingID
        if observedBindingID != currentBinding {
            retireAuthoringCapture()
        }
        observedBindingID = currentBinding
        editorObservation = editor.observe { [weak self] event in
            guard let self else { return }
            switch event {
            case let .snapshotChanged(snapshot):
                if observedBindingID != snapshot.bindingID {
                    retireAuthoringCapture()
                    observedBindingID = snapshot.bindingID
                }
            case .detached:
                observedBindingID = nil
                retireAuthoringCapture()
            }
        }
    }

    func stopObserving() {
        editorObservation?.cancel()
        editorObservation = nil
    }

    func requestPicker(scope: IOSWorkspaceScope) {
        guard !isOpening, pickerRequest == nil else { return }
        scene.dismissPresentation()
        authoring.linkDraft = nil
        pickerRequest = IOSProductionPickerRequest(scope: scope)
    }

    @discardableResult
    func completePicker(_ request: IOSProductionPickerRequest, urls: [URL]) -> Task<Void, Never>? {
        guard pickerRequest?.id == request.id else { return nil }
        pickerRequest = nil
        guard urls.count == 1, let url = urls.first, !isOpening else { return nil }
        // Reserve synchronously before creating the task. The access provider
        // starts/retains the security scope; UI never mints a second grant.
        isOpening = true
        return Task { await performOpen(url, scope: request.scope) }
    }

    func openURL(_ url: URL) async {
        guard !isOpening else { return }
        isOpening = true
        await performOpen(url, scope: .singleFile)
    }

    func setSceneActive(_ active: Bool) {
        guard active != isSceneActive else { return }
        isSceneActive = active
        if active {
            defer { inactiveFocus = nil }
            guard let focus = inactiveFocus,
                  let current = editor.captureSnapshot(),
                  current.revision.documentID == focus.identity,
                  current.bindingID == focus.bindingID
            else { return }
            _ = controller.setCommandFocus(true, expected: focus.identity, bindingID: focus.bindingID)
        } else {
            if let current = editor.captureSnapshot(), current.isFocused {
                inactiveFocus = (current.revision.documentID, current.bindingID)
            }
            scene.releaseCommandFocus()
        }
    }

    private func performOpen(_ url: URL, scope: IOSWorkspaceScope) async {
        defer { isOpening = false }
        do {
            try await openPickedURL(url, scope)
            if scope == .singleFile, controller.snapshot.document != nil {
                // Do not navigate for a cancelled/refused/failed open.
                scene.navigateToDocument()
            }
        } catch is CancellationError {
            return
        } catch {
            show(error, title: "Couldn't Open")
        }
    }

    private func installSurfaces() {
        scene.surfaces = IOSShellFeatureSurfaces(
            authoring: authoring,
            imageInsertion: images,
            makeEditorView: { [editor] binding in
                guard binding === editor else { return nil }
                return editor.textView
            },
            makePreviewView: { [preview] controller in
                guard controller === preview else { return nil }
                return preview.webView
            },
            makeAuthoringPanel: { [weak self] panel, context in
                self?.authoringPanel(panel, context: context)
            },
            makeImagePicker: { [weak self] context in
                self?.imagePanel(context: context)
            },
            currentGrant: currentGrant,
            refreshWorkspace: { [weak self] in
                guard let self else { return }
                Task {
                    do { try await refreshWorkspace() }
                    catch is CancellationError { return }
                    catch { show(error, title: "Couldn't Refresh") }
                }
            },
            openWorkspace: { [weak self] in self?.showOpenChoices = true }
        )
    }

    private func authoringPanel(
        _ panel: IOSShellAuthoringPanel,
        context: IOSShellSheetContext
    ) -> AnyView? {
        guard context.editor === editor else { return nil }
        let contextID = ObjectIdentifier(context)
        if hostedContextID == contextID {
            return hostedSheet
        }
        _ = scene.claimCommandFocus()
        context.onDismiss { [weak self] in
            self?.clearAuthoringCapture()
            self?.clearHostedSheet(contextID)
        }
        let content: AnyView
        switch panel {
        case .frontmatter:
            content = AnyView(IOSProductionFeatureSheet(title: "Frontmatter", scene: scene) {
                IOSAuthoringFrontmatterPanel(controller: authoring, editor: editor)
            })
        case .findReplace:
            authoring.perform(.find, using: editor)
            content = AnyView(IOSProductionFeatureSheet(title: "Find and Replace", scene: scene) {
                IOSAuthoringFindBar(controller: authoring, editor: editor)
            })
        }
        hostedContextID = contextID
        hostedSheet = content
        return content
    }

    private func imagePanel(context: IOSShellSheetContext) -> AnyView? {
        guard context.editor === editor,
              let destination = context.destination,
              let grant = context.grant
        else { return nil }
        let contextID = ObjectIdentifier(context)
        if hostedContextID == contextID {
            return hostedSheet
        }
        _ = scene.claimCommandFocus()
        let session = IOSImageInsertionSession(
            controller: images, editor: editor, destination: destination, grant: grant,
            onRequestDirectoryGrant: { [weak self] in self?.requestPicker(scope: .directory) }
        )
        context.onDismiss { [weak self] in
            session.teardown()
            self?.clearHostedSheet(contextID)
        }
        let content = AnyView(IOSProductionFeatureSheet(title: "Insert Image", scene: scene) {
            IOSImageInsertionView(session: session)
        })
        hostedContextID = contextID
        hostedSheet = content
        return content
    }

    private func clearHostedSheet(_ contextID: ObjectIdentifier) {
        guard hostedContextID == contextID else { return }
        hostedContextID = nil
        hostedSheet = nil
    }

    private func retireAuthoringCapture() {
        scene.dismissPresentation()
        clearAuthoringCapture()
        hostedContextID = nil
        hostedSheet = nil
    }

    private func clearAuthoringCapture() {
        authoring.linkDraft = nil
        authoring.stopObservingFrontmatter()
        authoring.findScheduler.cancel()
        authoring.find = IOSFindModel()
    }

    private static func message(for error: Error) -> String {
        let access: IOSWorkspaceFailure? = if let failure = error as? IOSWorkspaceFailure {
            failure
        } else if let failure = error as? IOSDocumentFailure, case let .access(reason) = failure {
            reason
        } else {
            nil
        }
        switch access {
        case .permissionDenied, .grantChanged, .outsideGrant:
            return "Access is no longer available. Choose the file or folder again."
        case .offline, .downloading:
            return "The file isn't available yet. Check its download and connection, then try again."
        case .unsupportedType:
            return "Choose a Markdown or MDX document."
        case .notFound:
            return "The file could not be found. Choose it again in Files."
        case .readOnly:
            return "This location is read only. Choose a writable location."
        default:
            if let failure = error as? IOSDocumentFailure, failure == .conflict {
                return "Resolve the current document's changes before opening another document."
            }
            return "The operation couldn't finish. Try again or choose another file or folder."
        }
    }

    private func show(_ error: Error, title: String) {
        scene.presentedError = IOSShellError(title: title, message: Self.message(for: error))
    }
}

private struct IOSProductionFeatureSheet<Content: View>: View {
    let title: String
    @ObservedObject var scene: IOSShellSceneState
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            ScrollView { content.padding() }
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { scene.dismissPresentation() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}
