import EditorKitIOS
import Foundation
import MarkdownCore
import PreviewKitContracts
import WorkspaceCore
import WorkspaceKitIOS

/// One scene, one admitted UIDocument writer, and the exact session attached to
/// the native editor. This class never maintains a second editable source.
@MainActor
final class IOSDocumentSceneController: IOSAppSceneControlling {
    let capabilities: IOSSceneCapabilities
    let documents: any IOSDocumentStore
    let workspace: any IOSWorkspaceAccessProviding
    let editor: any IOSSourceEditorBinding
    let preview: any IOSPreviewControlling
    let assetContext: (IOSWorkspaceGrant) -> PreviewAssetAccessContext?
    /// Production injects the non-persisting destination path; protocol doubles
    /// may use ordinary open without extending the frozen access contract.
    let openDestinationFolder: @MainActor (URL) async throws -> IOSWorkspaceGrant
    var openExternalURL: ((URL) -> Void)?
    var onNavigationFailure: ((String) -> Void)?
    var onPreviewUnavailable: ((String) -> Void)? {
        didSet { deliverPendingPreviewUnavailable() }
    }

    private var pendingPreviewUnavailableMessage: String?

    private(set) var currentGrant: IOSWorkspaceGrant?
    var handle: IOSDocumentHandle?
    var bindingID: UUID?
    let admission: IOSSceneWriterAdmission
    var ownedTicket: IOSOpenDocumentAdmission.Ticket?
    var isShuttingDown = false
    var isDisposed = false
    var transitioning = false
    var recentTransitionActive = false
    var recentTransitionSuperseded = false
    var pendingRecentNavigation: IOSPendingRecentNavigation?
    var recoveryEpoch: UInt64 = 0
    var grantIsCurrent = false
    var workspaceSnapshot: IOSWorkspaceSnapshot?
    var unavailableReason: String?
    var observers: [UUID: IOSSceneObservation] = [:]
    var documentObservation: (any IOSObservation)?
    var workspaceObservation: (any IOSObservation)?
    var editorObservation: (any IOSObservation)?
    var previewObservation: (any IOSObservation)?
    var renderTask: Task<Void, Never>?
    var renderedRevision: IOSDocumentRevision?
    lazy var reloadRelay = IOSDocumentReloadRelay(documents: documents, editor: editor)

    /// Observation can replay `contentRuleUnavailable` before production assigns
    /// `onPreviewUnavailable`. Keep the message until that callback exists.
    func noteContentRuleUnavailable() {
        pendingPreviewUnavailableMessage = PreviewNetworkPolicyFailure.userMessage
        deliverPendingPreviewUnavailable()
    }

    private func deliverPendingPreviewUnavailable() {
        guard let message = pendingPreviewUnavailableMessage, let onPreviewUnavailable else { return }
        pendingPreviewUnavailableMessage = nil
        onPreviewUnavailable(message)
    }

    init(
        documents: any IOSDocumentStore,
        workspace: any IOSWorkspaceAccessProviding,
        editor: any IOSSourceEditorBinding,
        preview: any IOSPreviewControlling,
        assets: any IOSWorkspaceAssetWriting,
        admission: IOSSceneWriterAdmission? = nil,
        assetContext: @escaping (IOSWorkspaceGrant) -> PreviewAssetAccessContext?,
        openDestinationFolder: (@MainActor (URL) async throws -> IOSWorkspaceGrant)? = nil
    ) {
        self.documents = documents
        self.workspace = workspace
        self.editor = editor
        self.preview = preview
        self.assetContext = assetContext
        self.openDestinationFolder = openDestinationFolder ?? { url in
            try await workspace.open(selectedURL: url, scope: .directory)
        }
        self.admission = admission ?? IOSSceneWriterAdmission()
        capabilities = IOSSceneCapabilities(
            editor: editor, documents: documents, workspace: workspace, preview: preview, assets: assets
        )
        documentObservation = documents.observe { [weak self] in self?.documentEvent($0) }
        workspaceObservation = workspace.observe { [weak self] in self?.workspaceEvent($0) }
        editorObservation = editor.observe { [weak self] event in
            guard let self, case let .snapshotChanged(snapshot) = event,
                  snapshot.revision.documentID == handle?.identity,
                  snapshot.bindingID == bindingID else { return }
            publish()
            requestRender()
        }
        previewObservation = preview.observe { [weak self] in self?.previewEvent($0) }
    }

    var snapshot: IOSAppSceneSnapshot {
        let stored = handle.flatMap { documents.snapshot(for: $0.identity) }
        return IOSAppSceneSnapshot(
            document: stored,
            documentState: handle.flatMap { documents.state(for: $0.identity) },
            workspace: workspaceSnapshot,
            unavailableReason: unavailableReason
        )
    }

    /// Only the explicit picker/OS Open URL path may mint a new grant. Browser
    /// rows and preview links use openSelectedURL and existing descriptors.
    func openPickedURL(_ url: URL, scope: IOSWorkspaceScope) async throws {
        try await waitForRecentTransition(preserving: nil)
        try beginTransition()
        defer { finishTransition() }
        try await closeCurrent()
        if let old = currentGrant {
            _ = workspace.invalidate(old.workspaceID)
        }
        currentGrant = nil
        grantIsCurrent = false
        workspaceSnapshot = nil
        publish()
        let grant = try await workspace.open(selectedURL: url, scope: scope)
        currentGrant = grant
        grantIsCurrent = true
        do {
            let fresh = try await workspace.refresh(grant)
            guard grantIsCurrent, currentGrant?.workspaceID == grant.workspaceID,
                  currentGrant?.accessGeneration == grant.accessGeneration
            else {
                throw IOSWorkspaceFailure.grantChanged
            }
            workspaceSnapshot = fresh
            // The new grant has passed refresh; retire errors from the old scope.
            // Clear before install can suspend and receive a new revocation.
            clearUnavailableReasonForCurrentGrant()
            if scope == .singleFile {
                let location = try pickedDocumentLocation(for: url)
                try await install(location, initialText: nil)
            }
        } catch {
            if handle == nil, !retainsPendingSelection(after: error, grant: grant) {
                _ = workspace.invalidate(grant.workspaceID)
                currentGrant = nil
                grantIsCurrent = false
                workspaceSnapshot = nil
            }
            throw error
        }
    }

    func openSelectedURL(_ url: URL, scope: IOSWorkspaceScope) async throws {
        try await waitForRecentTransition(preserving: currentGrant)
        guard scope == .singleFile, let location = documentLocation(for: url) else {
            throw IOSDocumentFailure.access(.outsideGrant)
        }
        if let handle, Self.sameLocation(handle.location, location) {
            return
        }
        try beginTransition()
        defer { finishTransition() }
        try await closeCurrent()
        try await install(location, initialText: nil)
    }

    func createDocument(at parent: IOSFileLocation) async throws {
        let location = try newDocumentLocation(in: parent)
        try beginTransition()
        defer { finishTransition() }
        try await closeCurrent()
        try await install(location, initialText: "")
        if let grant = currentGrant {
            workspaceSnapshot = try await workspace.refresh(grant)
        }
    }

    func saveCurrentDocument() async throws -> IOSSaveAcknowledgement {
        guard !transitioning, let handle else { throw IOSDocumentFailure.unavailable }
        // The store alone validates and rebases the captured acknowledgement.
        return try await documents.save(handle.identity)
    }

    func resolveExternal(_ choice: IOSExternalResolution) async throws {
        guard let handle else { throw IOSDocumentFailure.unavailable }
        // Reload installation already defers through the native relay while
        // composing. Navigation and copy transitions still refuse marked text.
        if case .reload = choice {
            try beginTransition(allowMarkedText: true)
        } else {
            try beginTransition()
        }
        updateEditorAccess()
        publish()
        defer { finishTransition() }
        try await documents.resolveExternal(handle.identity, choice: choice)
    }

    func flushForBackground() async -> [IOSDocumentFlushOutcome] {
        if let handle, let bindingID {
            editor.updateCommandFocus(for: handle.identity, bindingID: bindingID, isFocused: false)
        }
        return await documents.flushForBackground()
    }

    func refreshWorkspace() async throws {
        guard grantIsCurrent, let grant = currentGrant else { throw IOSWorkspaceFailure.unavailable }
        let fresh = try await workspace.refresh(grant)
        guard grantIsCurrent, currentGrant?.workspaceID == grant.workspaceID,
              currentGrant?.accessGeneration == grant.accessGeneration
        else {
            throw IOSWorkspaceFailure.grantChanged
        }
        workspaceSnapshot = fresh
        publish()
    }

    func setCommandFocus(_ focused: Bool, expected: IOSDocumentIdentity, bindingID: UUID) -> Bool {
        guard !transitioning, !isShuttingDown, handle?.identity == expected,
              self.bindingID == bindingID else { return false }
        editor.updateCommandFocus(for: expected, bindingID: bindingID, isFocused: focused)
        return editor.captureSnapshot()?.isFocused == focused
    }

    func observe(_ handler: @escaping @MainActor (IOSAppSceneSnapshot) -> Void) -> any IOSObservation {
        let token = UUID()
        let observation = IOSSceneObservation(handler: handler) { [weak self] in self?.observers[token] = nil }
        observers[token] = observation
        handler(snapshot)
        return observation
    }

    func beginTransition(allowMarkedText: Bool = false) throws {
        guard !transitioning, !isShuttingDown, !isDisposed else { throw IOSDocumentFailure.unavailable }
        guard allowMarkedText || editor.captureSnapshot()?.hasMarkedText != true else {
            throw IOSDocumentFailure.sourceChanged
        }
        recoveryEpoch &+= 1
        transitioning = true
    }

    func finishTransition() {
        transitioning = false
        updateEditorAccess()
        publish()
    }

    func closeCurrent() async throws {
        guard let handle else { return }
        renderTask?.cancel()
        if let bindingID {
            editor.updateCommandFocus(for: handle.identity, bindingID: bindingID, isFocused: false)
            editor.updateAccess(
                for: handle.identity, bindingID: bindingID,
                generation: documents.state(for: handle.identity)?.accessGeneration ?? handle.location.accessGeneration,
                canWrite: false
            )
        }
        switch try await documents.close(handle.identity) {
        case .closed:
            clearInstallation()
            clearUnavailableReasonForCurrentGrant()
        case .retained:
            // Keep the ticket/session/editor. A recovered draft is not permission
            // to retire its live writer or replace it with a second open.
            throw IOSDocumentFailure.closeFailed
        }
    }

    func clearUnavailableReasonForCurrentGrant() {
        // A revocation received while close was suspended still describes this scope.
        guard grantIsCurrent else { return }
        unavailableReason = nil
    }

    func install(_ location: IOSFileLocation, initialText: String?) async throws {
        guard grantIsCurrent, let grant = currentGrant, location.workspaceID == grant.workspaceID,
              location.accessGeneration == grant.accessGeneration else { throw IOSWorkspaceFailure.grantChanged }
        let intent = IOSDocumentIdentity(rawValue: UUID())
        guard case let .success(reservation) = admission.begin(documentID: intent) else {
            throw IOSDocumentFailure.unavailable
        }
        var adopted = false
        defer {
            if !adopted {
                admission.end(reservation)
            }
        }
        let lease = try workspace.acquireLease(for: grant)
        let opened: IOSDocumentHandle
        do {
            if let initialText {
                opened = try await documents.create(at: location, initialText: initialText, lease: lease)
            } else {
                opened = try await documents.open(location, lease: lease)
            }
        } catch {
            lease.release()
            throw error
        }
        // No suspension between replacing the opening reservation and attaching
        // the store-issued identity. The store is the sole session constructor.
        admission.end(reservation)
        guard case let .success(ticket) = admission.begin(documentID: opened.identity) else {
            preconditionFailure("Writer admission changed inside synchronous installation")
        }
        ownedTicket = ticket
        adopted = true
        handle = opened
        let binding = UUID()
        bindingID = binding
        let state = documents.state(for: opened.identity)
        editor.attach(IOSSourceEditorDocumentBinding(
            bindingID: binding, identity: opened.identity, session: opened.session,
            accessGeneration: state?.accessGeneration ?? location.accessGeneration,
            canWrite: (state?.canWrite ?? false) && grantIsCurrent && !transitioning
        ))
        updateEditorAccess()
        renderedRevision = nil
        requestRender(immediate: true)
        publish()
        guard grantIsCurrent, !lease.isReleased, currentGrant?.workspaceID == grant.workspaceID,
              currentGrant?.accessGeneration == grant.accessGeneration
        else {
            // Keep the returned writer/session admitted and read-only until safe
            // close; never drop an asynchronously opened writer on revocation.
            throw IOSWorkspaceFailure.grantChanged
        }
    }

    func releaseCurrentGrant() {
        let grant = currentGrant
        currentGrant = nil
        grantIsCurrent = false
        workspaceSnapshot = nil
        if let grant {
            _ = workspace.invalidate(grant.workspaceID)
        }
    }

    /// Composition may replace authority only inside an admitted transition
    /// after the old writer safely closed. No await between proof and adoption.
    func adoptCurrentGrant(_ grant: IOSWorkspaceGrant, snapshot: IOSWorkspaceSnapshot) throws {
        guard transitioning, !isShuttingDown, !isDisposed,
              handle == nil, bindingID == nil, ownedTicket == nil, admission.active == nil,
              snapshot.workspaceID == grant.workspaceID, snapshot.accessGeneration == grant.accessGeneration
        else { throw IOSDocumentFailure.documentChanged }
        // Retiring the old scope can synchronously notify observers that revoke
        // this provisional scope. Prove authority after those callbacks, then
        // hold the proof through adoption so release-time revocation is observed
        // against the newly installed currentGrant.
        releaseCurrentGrant()
        let proof = try workspace.acquireLease(for: grant)
        defer { proof.release() }
        currentGrant = grant
        grantIsCurrent = true
        workspaceSnapshot = snapshot
        clearUnavailableReasonForCurrentGrant()
    }

    func clearInstallation() {
        reloadRelay.detach()
        renderTask?.cancel()
        renderTask = nil
        if let handle, let bindingID {
            editor.detach(expected: handle.identity, bindingID: bindingID)
        }
        if let ticket = ownedTicket {
            admission.end(ticket)
        }
        ownedTicket = nil
        handle = nil
        bindingID = nil
        renderedRevision = nil
    }

    func documentLocation(for url: URL) -> IOSFileLocation? {
        guard let entry = documentEntry(for: url), case .available = entry.availability else { return nil }
        return entry.location
    }

    func documentEntry(for url: URL) -> IOSWorkspaceEntry? {
        guard grantIsCurrent, let grant = currentGrant, let tree = workspaceSnapshot,
              tree.workspaceID == grant.workspaceID, tree.accessGeneration == grant.accessGeneration else { return nil }
        return Self.flatten(tree.entries).first {
            guard case .document = $0.kind else { return false }
            return $0.location.fileURL.isFileURL && url.isFileURL &&
                $0.location.fileURL.path(percentEncoded: false).utf8.elementsEqual(url.path(percentEncoded: false).utf8)
        }
    }

    static func flatten(_ entries: [IOSWorkspaceEntry]) -> [IOSWorkspaceEntry] {
        entries.flatMap { [$0] + flatten($0.children) }
    }

    static func sameLocation(_ lhs: IOSFileLocation, _ rhs: IOSFileLocation) -> Bool {
        lhs.workspaceID == rhs.workspaceID && lhs.accessGeneration == rhs.accessGeneration &&
            lhs.relativePath.utf8.elementsEqual(rhs.relativePath.utf8)
    }
}

extension IOSDocumentSceneController {
    func pickedDocumentLocation(for url: URL) throws -> IOSFileLocation {
        guard let entry = documentEntry(for: url) else { throw IOSDocumentFailure.access(.unsupportedType) }
        switch entry.availability {
        case .available: return entry.location
        case .downloading: throw IOSDocumentFailure.access(.downloading)
        case .offline: throw IOSDocumentFailure.access(.offline)
        case .unavailable: throw IOSDocumentFailure.access(.unavailable)
        case .removed: throw IOSDocumentFailure.access(.notFound)
        }
    }

    func retainsPendingSelection(after error: Error, grant: IOSWorkspaceGrant) -> Bool {
        let failure: IOSWorkspaceFailure? = if let documentFailure = error as? IOSDocumentFailure,
                                               case let .access(reason) = documentFailure
        {
            reason
        } else {
            error as? IOSWorkspaceFailure
        }
        // A cloud download is not a type or permission failure. Retain only the
        // still-current explicit selection so Files can refresh and retry it.
        return (failure == .downloading || failure == .offline) && grant.scope == .singleFile && grantIsCurrent &&
            currentGrant?.workspaceID == grant.workspaceID && currentGrant?.accessGeneration == grant.accessGeneration
    }
}

@MainActor
final class IOSSceneObservation: IOSObservation {
    var handler: (@MainActor (IOSAppSceneSnapshot) -> Void)?
    var onCancel: (() -> Void)?
    init(handler: @escaping @MainActor (IOSAppSceneSnapshot) -> Void, onCancel: @escaping () -> Void) {
        self.handler = handler
        self.onCancel = onCancel
    }

    func cancel() {
        handler = nil
        onCancel?()
        onCancel = nil
    }
}
