import EditorKitIOS
import Foundation
import MarkdownCore
import PreviewKitContracts
import SwiftUI
import UIKit
import WorkspaceCore
import WorkspaceKitIOS

/// Per-scene shell state. Created once per scene by composition (13) or by
/// test/preview harnesses with fakes; never app-global. Owns navigation,
/// layout, presentation and the deduplicated chrome projection; every
/// document/workspace/write operation delegates to the frozen facade.
@MainActor
final class IOSShellSceneState: ObservableObject {
    let facade: any IOSAppSceneControlling
    var surfaces: IOSShellFeatureSurfaces

    @Published private(set) var chrome: IOSShellChromeSnapshot
    @Published private(set) var workspaceSnapshot: IOSWorkspaceSnapshot?
    @Published private(set) var layout: IOSContentLayout
    @Published var preferredPane: IOSEditorPane = .source
    @Published private(set) var presentation: IOSShellPresentation?
    @Published var navigationPath: [IOSShellRoute] = []
    @Published var selectedEntryID: IOSWorkspaceEntry.ID?
    @Published var presentedError: IOSShellError?

    /// Latest observed editor snapshot. Read at action time, never published
    /// per keystroke — chrome carries the deduplicated projection instead.
    private(set) var editorSnapshot: IOSSourceEditorSnapshot?
    private(set) var sceneSnapshot: IOSAppSceneSnapshot
    private(set) var sheetContext: IOSShellSheetContext?
    let hostedViews = IOSSceneHostedViews()

    private var facadeObservation: (any IOSObservation)?
    private var editorObservation: (any IOSObservation)?
    private var observedEditorID: ObjectIdentifier?
    private var lastContentWidth: CGFloat = 0
    private var lastPrefersRegularWidth = false
    private var isObserving = false

    init(
        facade: any IOSAppSceneControlling,
        surfaces: IOSShellFeatureSurfaces = IOSShellFeatureSurfaces()
    ) {
        self.facade = facade
        self.surfaces = surfaces
        sceneSnapshot = facade.snapshot
        workspaceSnapshot = facade.snapshot.workspace
        chrome = IOSShellChromeSnapshot(scene: facade.snapshot, editor: nil)
        layout = .single(.source)
    }

    // MARK: Observation

    /// Called by the root view's onAppear. Idempotent.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        editorSnapshot = facade.capabilities.editor?.captureSnapshot()
        facadeObservation = facade.observe { [weak self] snapshot in
            self?.apply(sceneSnapshot: snapshot)
        }
        observeEditorIfNeeded()
        republishChrome()
    }

    /// Release observations on scene teardown.
    func stopObserving() {
        facadeObservation?.cancel()
        facadeObservation = nil
        editorObservation?.cancel()
        editorObservation = nil
        observedEditorID = nil
        isObserving = false
    }

    private func apply(sceneSnapshot snapshot: IOSAppSceneSnapshot) {
        let previousIdentity = sceneSnapshot.document?.revision.documentID
        sceneSnapshot = snapshot
        if !IOSShellWorkspaceProjection.matches(workspaceSnapshot, snapshot.workspace) {
            workspaceSnapshot = snapshot.workspace
        }
        let identity = snapshot.document?.revision.documentID
        if previousIdentity != identity {
            // A pending sheet proposal is bound to the old document's capture;
            // leaving it up would only produce refusals against the new one.
            dismissPresentation()
            if identity == nil {
                navigationPath = []
            }
        }
        observeEditorIfNeeded()
        republishChrome()
    }

    private func observeEditorIfNeeded() {
        guard let editor = facade.capabilities.editor else {
            editorObservation?.cancel()
            editorObservation = nil
            observedEditorID = nil
            editorSnapshot = nil
            return
        }
        let identifier = ObjectIdentifier(editor)
        guard observedEditorID != identifier else { return }
        editorObservation?.cancel()
        observedEditorID = identifier
        editorSnapshot = editor.captureSnapshot()
        editorObservation = editor.observe { [weak self] event in
            self?.handle(editorEvent: event)
        }
    }

    private func handle(editorEvent event: IOSSourceEditorEvent) {
        switch event {
        case let .snapshotChanged(snapshot):
            editorSnapshot = snapshot
        case let .detached(_, bindingID):
            if editorSnapshot?.bindingID == bindingID {
                editorSnapshot = nil
            }
        }
        republishChrome()
    }

    private func republishChrome() {
        let next = IOSShellChromeSnapshot(scene: sceneSnapshot, editor: editorSnapshot)
        if next != chrome {
            chrome = next
        }
    }

    // MARK: Layout

    /// Recomputes the content layout from the actual document-area width and
    /// size class. Both panes stay mounted regardless of the result.
    func updateLayout(prefersRegularWidth: Bool, contentWidth: CGFloat) {
        lastPrefersRegularWidth = prefersRegularWidth
        lastContentWidth = contentWidth
        let next = IOSContentLayoutPolicy.layout(
            prefersRegularWidth: prefersRegularWidth,
            contentWidth: contentWidth,
            preferredPane: preferredPane
        )
        if next != layout {
            layout = next
        }
    }

    /// The preferred single pane changed (segmented control / toggle button).
    /// In side-by-side mode this is a no-op for layout; in toggle mode the
    /// visibility flips without touching the native views.
    func showPane(_ pane: IOSEditorPane) {
        preferredPane = pane
        if case .single = layout {
            layout = .single(pane)
        }
    }

    // MARK: Hosted views

    var currentEditor: (any IOSSourceEditorControlling)? {
        facade.capabilities.editor
    }

    var editorHostView: UIView? {
        hostedViews.editorView(for: facade.capabilities.editor, make: surfaces.makeEditorView)
    }

    var previewHostView: UIView? {
        hostedViews.previewView(for: facade.capabilities.preview, make: surfaces.makePreviewView)
    }

    // MARK: Command focus

    /// Re-validate command ownership against the facade at dispatch time.
    /// Returns false when the expected binding is no longer the installed one —
    /// a stale editor can never receive commands through this path.
    @discardableResult
    func claimCommandFocus() -> Bool {
        guard let snapshot = editorSnapshot else { return false }
        return facade.setCommandFocus(
            true,
            expected: snapshot.revision.documentID,
            bindingID: snapshot.bindingID
        )
    }

    func releaseCommandFocus() {
        guard let snapshot = editorSnapshot else { return }
        _ = facade.setCommandFocus(
            false,
            expected: snapshot.revision.documentID,
            bindingID: snapshot.bindingID
        )
    }

    // MARK: Sheets

    /// The current sheet's context (for hosted content factories).
    /// Image-pick presentation captures the open Markdown document and the
    /// current grant up front — the flow must not retarget after the user
    /// moves the caret or changes selection mid-pick (09's contract).
    /// The writer derives the asset directory from this document's parent.
    func present(_ sheet: IOSShellPresentation) {
        guard presentation != sheet else { return }
        dismissPresentation()
        let context = IOSShellSheetContext(
            facade: facade,
            editor: currentEditor,
            presentation: sheet,
            destination: sheet == .imagePicker ? sceneSnapshot.document?.location : nil,
            grant: sheet == .imagePicker ? surfaces.currentGrant?() : nil
        )
        sheetContext = context
        presentation = sheet
    }

    /// User cancel, sheet swipe-down or a document switch all funnel here.
    /// Dismissal notifies hosted content exactly once and never commits a
    /// pending proposal on its behalf.
    func dismissPresentation() {
        guard presentation != nil else { return }
        presentation = nil
        let context = sheetContext
        sheetContext = nil
        context?.notifyDismissed()
    }

    var isPresentingSheet: Bool {
        presentation != nil
    }

    // MARK: Facade-delegated operations

    var sceneWorkspaceEntries: [IOSWorkspaceEntry] {
        workspaceSnapshot?.entries ?? []
    }

    func openSelectedURL(_ url: URL, scope: IOSWorkspaceScope) {
        perform {
            try await self.facade.openSelectedURL(url, scope: scope)
        }
    }

    /// Open a file entry from the workspace browser.
    func openEntry(_ entry: IOSWorkspaceEntry) {
        guard case .document = entry.kind,
              case .available = entry.availability
        else {
            return
        }
        selectedEntryID = entry.id
        openSelectedURL(entry.location.fileURL, scope: .singleFile)
    }

    /// Compact stacks push `.document` when the user taps a file row (even the
    /// already-open one). A no-op in regular width, where the document is the
    /// always-visible detail column.
    func navigateToDocument() {
        guard !navigationPath.contains(.document) else { return }
        navigationPath.append(.document)
    }

    /// New File only uses the current directory grant. A file URL or an
    /// existing row cannot authorize its parent, including an empty workspace.
    var newFileTarget: IOSFileLocation? {
        guard let workspace = workspaceSnapshot,
              let grant = surfaces.currentGrant?(), grant.scope == .directory,
              grant.workspaceID == workspace.workspaceID,
              grant.accessGeneration == workspace.accessGeneration
        else { return nil }
        if let selected = selectedEntryID.flatMap({ id in sceneWorkspaceEntries.depthFirstFirst { $0.id == id } }),
           selected.location.workspaceID == grant.workspaceID,
           selected.location.accessGeneration == grant.accessGeneration,
           WorkspaceRelativePath(spelling: selected.location.relativePath) != nil,
           case .available(canWrite: true) = selected.availability
        {
            if case .directory = selected.kind {
                return selected.location
            }
            if let parent = selected.location.parentDirectoryLocation {
                return parent
            }
        }
        return IOSFileLocation(
            workspaceID: grant.workspaceID, accessGeneration: grant.accessGeneration,
            relativePath: "", fileURL: grant.rootURL, resourceID: nil
        )
    }

    func createDocument() {
        guard let target = newFileTarget else { return }
        perform {
            try await self.facade.createDocument(at: target)
        }
    }

    func saveCurrentDocument() {
        perform {
            _ = try await self.facade.saveCurrentDocument()
        }
    }

    func resolveExternal(_ choice: IOSExternalResolution) {
        perform {
            try await self.facade.resolveExternal(choice)
        }
    }

    /// Retry opening an unavailable document at its last known location.
    func retryOpenUnavailableDocument() {
        guard let location = sceneSnapshot.document?.location else { return }
        openSelectedURL(location.fileURL, scope: .singleFile)
    }

    func flushForBackground() {
        Task { @MainActor in
            _ = await facade.flushForBackground()
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                presentedError = IOSShellError(
                    title: "Couldn't Complete",
                    message: String(describing: error)
                )
            }
        }
    }

    func dismissError() {
        presentedError = nil
    }
}
