import EditorKitIOS
import Foundation
import MarkdownCore
import PreviewKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WorkspaceCore
import WorkspaceKitIOS

private struct IOSProductionFocus: Equatable {
    let identity: IOSDocumentIdentity
    let bindingID: UUID
}

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
    let recovery: IOSRecoveryController?
    let conflictCopy: IOSConflictCopyCoordinator?
    let recentPresentation = IOSRecentPresentationController()
    let exporter = IOSDocumentExportController()
    let typewriter = IOSTypewriterSync()
    var previewThemeName = "system"
    var systemAppearanceIsDark = false
    var typewriterRequested = false

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
    private var inactiveFocus: IOSProductionFocus?
    private var pendingFocus: IOSProductionFocus?
    private var focusTask: Task<Void, Never>?
    private let shutdownProvider: @MainActor () async -> Bool
    private let readWorkspaceDocument: (@MainActor (IOSFileLocation) async throws -> String)?
    private var shutdownTask: Task<Bool, Never>?
    private var isShutDown = false
    private var isShuttingDown = false
    private var pendingOpen: (url: URL, scope: IOSWorkspaceScope)?
    private var disconnectObserver: IOSWindowSceneDisconnectObserver?

    init(
        controller: any IOSAppSceneControlling,
        editor: IOSSourceEditorController,
        preview: PreviewController,
        currentGrant: @escaping () -> IOSWorkspaceGrant?,
        refreshWorkspace: @escaping @MainActor () async throws -> Void,
        openPickedURL: @escaping @MainActor (URL, IOSWorkspaceScope) async throws -> Void,
        shutdown: @escaping @MainActor () async -> Bool,
        recovery: IOSRecoveryController? = nil,
        conflictCopy: IOSConflictCopyCoordinator? = nil,
        readWorkspaceDocument: (@MainActor (IOSFileLocation) async throws -> String)? = nil
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
        shutdownProvider = shutdown
        self.recovery = recovery
        self.conflictCopy = conflictCopy
        self.readWorkspaceDocument = readWorkspaceDocument
        images = IOSImageInsertionController(writer: assets)
        scene = IOSShellSceneState(facade: controller)
        installSurfaces()
        installTypewriter()
        recentPresentation.bind(to: self)
    }

    private func installTypewriter() {
        editor.onViewportLine = { [weak self] line in
            self?.typewriter.editorViewportChanged(to: line)
        }
        typewriter.scrollPreview = { [weak self] line in
            self?.preview.scrollToLine(line, animated: false)
        }
        typewriter.scrollEditor = { [weak self] line in
            self?.editor.scrollToSourceLine(line)
        }
        preview.onPreviewScrolled = { [weak self] line in
            self?.typewriter.previewScrolled(to: line)
        }
        scene.onLayoutChange = { [weak self] layout in
            self?.applyTypewriter(layout: layout)
        }
    }

    func applyTypewriter(layout: IOSContentLayout) {
        typewriter.setEnabled(
            typewriterRequested && layout.showsPreview,
            editorLine: editor.topVisibleSourceLine()
        )
    }

    func startObserving() {
        guard !isShutDown, editorObservation == nil else { return }
        let currentBinding = editor.captureSnapshot()?.bindingID
        if observedBindingID != currentBinding {
            retireAuthoringCapture()
        }
        observedBindingID = currentBinding
        if let snapshot = editor.captureSnapshot() {
            noteNewBinding(snapshot)
        }
        editorObservation = editor.observe { [weak self] event in
            guard let self else { return }
            switch event {
            case let .snapshotChanged(snapshot):
                if observedBindingID != snapshot.bindingID {
                    exporter.cancel()
                    retireAuthoringCapture()
                    observedBindingID = snapshot.bindingID
                    noteNewBinding(snapshot)
                }
                queueCommandFocus(snapshot)
            case .detached:
                exporter.cancel()
                observedBindingID = nil
                pendingFocus = nil
                focusTask?.cancel()
                retireAuthoringCapture()
            }
        }
    }

    func stopObserving() {
        exporter.cancel()
        editorObservation?.cancel()
        editorObservation = nil
        focusTask?.cancel()
        focusTask = nil
        pendingFocus = nil
    }

    func observeSceneDisconnection(_ scene: UIWindowScene) {
        guard !isShutDown else { return }
        if disconnectObserver == nil {
            disconnectObserver = IOSWindowSceneDisconnectObserver { [self] in _ = await shutdown() }
        }
        disconnectObserver?.bind(to: scene)
    }

    func shutdown() async -> Bool {
        exporter.cancel()
        pendingOpen = nil
        pickerRequest = nil
        recentPresentation.cancel()
        recovery?.dismiss()
        if isShutDown {
            return true
        }
        if let shutdownTask {
            return await shutdownTask.value
        }
        isShuttingDown = true
        let task = Task { @MainActor [self] in await shutdownProvider() }
        shutdownTask = task
        let closed = await task.value
        shutdownTask = nil
        isShuttingDown = false
        if closed {
            isShutDown = true
            stopObserving()
            disconnectObserver?.stop()
            disconnectObserver = nil
            preview.invalidate()
        }
        return closed
    }

    func requestPicker(scope: IOSWorkspaceScope) {
        guard !isShutDown, !isShuttingDown, !isOpening, pickerRequest == nil else { return }
        if recentPresentation.redirectPickerUntilDismissed(scope: scope) {
            return
        }
        scene.dismissPresentation()
        authoring.linkDraft = nil
        pickerRequest = IOSProductionPickerRequest(scope: scope)
    }

    @discardableResult
    func completePicker(_ request: IOSProductionPickerRequest, urls: [URL]) -> Task<Void, Never>? {
        guard !isShuttingDown, pickerRequest?.id == request.id else { return nil }
        pickerRequest = nil
        guard urls.count == 1, let url = urls.first, !isOpening else { return nil }
        // Reserve synchronously before creating the task. The access provider
        // starts/retains the security scope; UI never mints a second grant.
        isOpening = true
        return Task { await performOpen(url, scope: request.scope) }
    }

    func openURL(_ url: URL) async {
        recovery?.dismiss()
        // An OS delivery supersedes a still-presented picker. Retire its
        // issuance before any await so its delayed delegate cannot replace it.
        pickerRequest = nil
        showOpenChoices = false
        recentPresentation.cancel()
        retireAuthoringCapture()
        guard !isShutDown, !isShuttingDown else { return }
        if isOpening {
            // Preserve the latest OS delivery while a Recent/picker provider
            // drains. Never run a second grant or writer operation in parallel.
            pendingOpen = (url, .singleFile)
            return
        }
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
                inactiveFocus = IOSProductionFocus(identity: current.revision.documentID, bindingID: current.bindingID)
            }
            pendingFocus = nil
            focusTask?.cancel()
            focusTask = nil
            scene.releaseCommandFocus()
        }
    }

    private func noteNewBinding(_ snapshot: IOSSourceEditorSnapshot) {
        guard isSceneActive else { return }
        pendingFocus = IOSProductionFocus(identity: snapshot.revision.documentID, bindingID: snapshot.bindingID)
        queueCommandFocus(snapshot)
    }

    private func queueCommandFocus(_ snapshot: IOSSourceEditorSnapshot) {
        guard isSceneActive, let expected = pendingFocus,
              snapshot.revision.documentID == expected.identity,
              snapshot.bindingID == expected.bindingID else { return }
        focusTask?.cancel()
        focusTask = Task { @MainActor [weak self] in
            // attach emits inside the controller's transition. A later access
            // snapshot retries if that transition still refuses this first turn.
            await Task.yield()
            guard !Task.isCancelled, let self, isSceneActive,
                  pendingFocus == expected,
                  let current = editor.captureSnapshot(),
                  current.revision.documentID == expected.identity,
                  current.bindingID == expected.bindingID else { return }
            pendingFocus = nil
            let accepted = controller.setCommandFocus(true, expected: expected.identity, bindingID: expected.bindingID)
            if !accepted, pendingFocus == nil, isSceneActive,
               editor.captureSnapshot()?.bindingID == expected.bindingID
            {
                pendingFocus = expected
            }
        }
    }

    private func performOpen(_ url: URL, scope: IOSWorkspaceScope) async {
        defer {
            isOpening = false
            recentPresentation.presenter?.reload()
        }
        var request = (url: url, scope: scope)
        var firstRequest = true
        while !isShutDown, !isShuttingDown {
            // Pending OS deliveries are separate user operations. A cancelled
            // picker caller must not cancel every later queued delivery.
            let operation = Task { @MainActor [request] in
                try Task.checkCancellation()
                try await self.openPickedURL(request.url, request.scope)
            }
            do {
                if firstRequest {
                    try await withTaskCancellationHandler {
                        try await operation.value
                    } onCancel: {
                        operation.cancel()
                    }
                } else {
                    try await operation.value
                }
                if pendingOpen == nil, !firstRequest || !Task.isCancelled,
                   !isShuttingDown, !isShutDown, request.scope == .singleFile,
                   controller.snapshot.document != nil
                {
                    scene.navigateToDocument()
                }
            } catch is CancellationError {
                // Cancellation suppresses UI completion, not a newer delivery.
            } catch {
                if pendingOpen == nil {
                    show(error, title: "Couldn't Open")
                }
            }
            guard let next = pendingOpen else { break }
            pendingOpen = nil
            request = next
            firstRequest = false
        }
    }
}

extension IOSProductionRuntime {
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
            readWorkspaceDocument: readWorkspaceDocument,
            resolveConflictCopy: conflictCopy == nil ? nil : { [weak self] in self?.requestConflictCopy() },
            refreshWorkspace: { [weak self] in
                guard let self else { return }
                Task {
                    do { try await self.refreshWorkspace() }
                    catch is CancellationError { return }
                    catch { self.show(error, title: "Couldn't Refresh") }
                }
            },
            openWorkspace: { [weak self] in self?.showOpenChoices = true },
            exportDocument: { [weak self] kind in self?.beginExport(kind) }
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

    private func show(_ error: Error, title: String) {
        scene.presentedError = IOSShellError(title: title, message: IOSOperationFeedback.message(for: error))
    }

    /// A read-only modal owns no source command route. Retire a yielded focus
    /// claim before releasing the route, without changing native text or Undo.
    func prepareForReadOnlyPresentation() {
        pendingFocus = nil
        focusTask?.cancel()
        focusTask = nil
        scene.releaseCommandFocus()
        retireAuthoringCapture()
    }

    func requestConflictCopy() {
        guard !isShutDown, !isShuttingDown, !isOpening, pickerRequest == nil,
              recovery?.isPresented != true, !recentPresentation.isActive, let conflictCopy else { return }
        prepareForReadOnlyPresentation()
        _ = conflictCopy.requestSaveCopy()
    }

    var canPresentRecentItems: Bool {
        !isShutDown && !isShuttingDown && !isOpening && pickerRequest == nil && !showOpenChoices &&
            recovery?.isPresented != true && conflictCopy?.draft?.id == nil && conflictCopy?.isSaving != true
    }
}

private struct IOSProductionFeatureSheet<Content: View>: View {
    let title: String
    @ObservedObject var scene: IOSShellSceneState
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            ScrollView { content.padding() }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { scene.dismissPresentation() }
                            .frame(minHeight: 44)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
