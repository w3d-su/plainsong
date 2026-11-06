import Combine
import Foundation
import MarkdownCore
import WorkspaceCore
import WorkspaceKitIOS

/// A destination-only flow over the scene's existing access service and writer.
/// It never opens/replaces/closes the origin or resolves its external conflict.
@MainActor
final class IOSConflictCopyCoordinator: ObservableObject {
    @Published private(set) var draft: IOSConflictCopyDraft?
    @Published private(set) var pickerRequest: IOSConflictCopyPickerRequest?
    @Published private(set) var isSaving = false
    @Published var notice: IOSConflictCopyNotice?
    @Published var validationNotice: IOSConflictCopyNotice?
    @Published private(set) var lastOutcome: IOSConflictCopyOutcome?

    private let controller: IOSDocumentSceneController
    private var origin: IOSConflictCopyOrigin?
    private var activePickerID: UUID?
    private var copyTask: Task<IOSConflictCopyOutcome, Never>?
    private var awaitingDismissalID: UUID?
    private var dismissedDraftID: UUID?
    private var pendingTerminalNotice: IOSConflictCopyNotice?

    init(controller: IOSDocumentSceneController) {
        self.controller = controller
    }

    @discardableResult
    func requestSaveCopy() -> Bool {
        guard draft == nil, !isSaving, awaitingDismissalID == nil else { return false }
        let id = UUID()
        do {
            let capture = try IOSConflictCopyOrigin(controller: controller, draftID: id)
            origin = capture
            lastOutcome = nil
            notice = nil
            validationNotice = nil
            dismissedDraftID = nil
            draft = IOSConflictCopyDraft(
                id: id, suggestedFilename: IOSConflictCopyFilename.suggested(
                    for: capture.handle.location.fileURL,
                    issuance: id
                )
            )
            return true
        } catch {
            let outcome = IOSConflictCopyOutcome.refused(.originChanged, copyMayExist: false)
            lastOutcome = outcome
            notice = IOSConflictCopyFeedback.notice(for: outcome)
            return false
        }
    }

    func cancelDraft(_ id: UUID) {
        guard draft?.id == id, !isSaving else { return }
        pickerRequest = nil
        origin = nil
        draft = nil
        validationNotice = nil
        lastOutcome = .cancelled
    }

    func requestFolderPicker(draftID: UUID, filename: String) -> IOSConflictCopyPickerRequest? {
        guard !isSaving, pickerRequest == nil, let capture = origin, capture.draftID == draftID else { return nil }
        do {
            try validateOrigin(capture, ownsTransition: false)
            let request = try IOSConflictCopyPickerRequest(
                id: UUID(), draftID: draftID, filename: IOSConflictCopyFilename.validate(filename)
            )
            pickerRequest = request
            validationNotice = nil
            return request
        } catch {
            let outcome = IOSConflictCopyOutcome.refused(
                (error as? IOSConflictCopyFailure) ?? .originChanged,
                copyMayExist: false
            )
            lastOutcome = outcome
            validationNotice = IOSConflictCopyFeedback.notice(for: outcome)
            return nil
        }
    }

    func cancelPicker(_ id: UUID) {
        guard pickerRequest?.id == id else { return }
        pickerRequest = nil
    }

    /// Consume the issuance synchronously so duplicate/late delegates cannot
    /// create two copies or attach a folder to a newer source capture.
    @discardableResult
    func completePicker(_ request: IOSConflictCopyPickerRequest, urls: [URL]) -> Task<IOSConflictCopyOutcome, Never>? {
        guard let issued = pickerRequest, issued.id == request.id, issued.draftID == request.draftID,
              IOSConflictCopyOrigin.exact(issued.filename, request.filename), request.draftID == draft?.id,
              let capture = origin, capture.draftID == request.draftID, !isSaving else { return nil }
        pickerRequest = nil
        guard urls.count == 1, let url = urls.first, url.isFileURL else { return nil }
        isSaving = true
        activePickerID = request.id
        let task = Task { @MainActor [self] in
            await performCopy(request, folder: url, capture: capture)
        }
        copyTask = task
        return task
    }

    /// Cancellation cannot release a scope or the transition while a provider
    /// create is still draining. The normal completion path owns all cleanup.
    func cancelInFlightCopy() {
        copyTask?.cancel()
    }

    /// SwiftUI's actual sheet dismissal transfers a queued terminal notice to
    /// its sole presenter. Repeated or older onDismiss callbacks do nothing.
    func nameSheetDidDismiss(_ draftID: UUID) {
        if draft?.id == draftID, isSaving {
            // A scene/presentation teardown can precede provider completion.
            // Remember the real dismissal without releasing the scope early.
            dismissedDraftID = draftID
            return
        }
        guard awaitingDismissalID == draftID else { return }
        awaitingDismissalID = nil
        dismissedDraftID = nil
        notice = pendingTerminalNotice
        pendingTerminalNotice = nil
    }

    private func performCopy(
        _ request: IOSConflictCopyPickerRequest, folder: URL, capture: IOSConflictCopyOrigin
    ) async -> IOSConflictCopyOutcome {
        var destinationGrant: IOSWorkspaceGrant?
        var destinationLease: (any IOSWorkspaceAccessLease)?
        var ownsTransition = false
        var copyWasIssued = false
        defer {
            finishCopy(grant: destinationGrant, lease: destinationLease, ownsTransition: ownsTransition)
        }
        do {
            try Task.checkCancellation()
            try validateOrigin(capture, ownsTransition: false)
            let grant = try await controller.openDestinationFolder(folder)
            // Never retire an origin scope, even if a broken provider returns it.
            guard grant.workspaceID != capture.grant.workspaceID
            else { throw IOSConflictCopyFailure.destinationChanged }
            destinationGrant = grant
            try Task.checkCancellation()
            try validateOrigin(capture, ownsTransition: false)
            guard grant.scope == .directory, grant.rootURL.isFileURL, IOSConflictCopyOrigin.exact(
                grant.rootURL.path(percentEncoded: false), folder.path(percentEncoded: false)
            ) else { throw IOSConflictCopyFailure.destinationChanged }
            let lease = try controller.workspace.acquireLease(for: grant)
            destinationLease = lease
            let destination = try await prepareDestination(request, grant: grant, lease: lease, capture: capture)
            try Task.checkCancellation()
            try validateOrigin(capture, ownsTransition: false)
            try validateDestination(grant, lease: lease)
            // No await between the final capture check and acquiring this fence.
            // Existing controller entry points reject navigation/reload/resolve.
            try controller.beginTransition()
            ownsTransition = true
            controller.updateEditorAccess()
            controller.publish()
            try validateOrigin(capture, ownsTransition: true)
            try validateDestination(grant, lease: lease)
            copyWasIssued = true
            let receipt = try await controller.documents.saveCopy(
                capture.handle.identity,
                destination: destination,
                lease: lease
            )
            try Task.checkCancellation()
            try validateOrigin(capture, ownsTransition: true)
            try validateDestination(grant, lease: lease)
            try validateReceipt(receipt, destination: destination, capture: capture)
            let outcome = IOSConflictCopyOutcome.saved(filename: request.filename)
            queueTerminal(outcome)
            return outcome
        } catch {
            let failure = IOSConflictCopyFeedback.failure(error)
            let outcome = IOSConflictCopyOutcome.refused(failure, copyMayExist: copyWasIssued)
            queueTerminal(outcome)
            return outcome
        }
    }

    private func finishCopy(grant: IOSWorkspaceGrant?, lease: (any IOSWorkspaceAccessLease)?, ownsTransition: Bool) {
        lease?.release()
        if let grant {
            _ = controller.workspace.invalidate(grant.workspaceID)
        }
        if ownsTransition {
            controller.finishTransition()
        }
        activePickerID = nil
        copyTask = nil
        isSaving = false
        pickerRequest = nil
        awaitingDismissalID = draft?.id
        let completedDraftID = draft?.id
        validationNotice = nil
        draft = nil
        origin = nil
        if let id = completedDraftID, dismissedDraftID == id {
            nameSheetDidDismiss(id)
        }
    }

    private func prepareDestination(
        _ request: IOSConflictCopyPickerRequest, grant: IOSWorkspaceGrant,
        lease: any IOSWorkspaceAccessLease, capture: IOSConflictCopyOrigin
    ) async throws -> IOSFileLocation {
        let tree = try await controller.workspace.refresh(grant)
        try Task.checkCancellation()
        try validateOrigin(capture, ownsTransition: false)
        try validateDestination(grant, lease: lease)
        guard tree.workspaceID == grant.workspaceID, tree.accessGeneration == grant.accessGeneration else {
            throw IOSConflictCopyFailure.destinationChanged
        }
        guard !IOSDocumentSceneController.flatten(tree.entries).contains(where: {
            IOSConflictCopyOrigin.exact($0.location.relativePath, request.filename)
        }) else { throw IOSConflictCopyFailure.alreadyExists }
        return IOSFileLocation(
            workspaceID: grant.workspaceID, accessGeneration: grant.accessGeneration,
            relativePath: request.filename, fileURL: grant.rootURL.appendingPathComponent(request.filename),
            resourceID: nil
        )
    }

    private func validateReceipt(
        _ receipt: IOSSaveAcknowledgement, destination: IOSFileLocation, capture: IOSConflictCopyOrigin
    ) throws {
        guard receipt.revision == capture.revision,
              IOSConflictCopyOrigin.exact(receipt.savedText, capture.source),
              receipt.location.workspaceID == destination.workspaceID,
              receipt.location.accessGeneration == destination.accessGeneration,
              IOSConflictCopyOrigin.exact(receipt.location.relativePath, destination.relativePath),
              receipt.location.fileURL.isFileURL,
              IOSConflictCopyOrigin.exact(
                  receipt.location.fileURL.path(percentEncoded: false), destination.fileURL.path(percentEncoded: false)
              )
        else { throw IOSConflictCopyFailure.sourceChanged }
    }
}

private extension IOSConflictCopyCoordinator {
    func validateOrigin(_ capture: IOSConflictCopyOrigin, ownsTransition: Bool) throws {
        guard draft?.id == capture.draftID, !isSaving || activePickerID != nil,
              controller.transitioning == ownsTransition, !controller.isShuttingDown, !controller.isDisposed,
              controller.grantIsCurrent == capture.grantWasCurrent,
              let current = controller.handle, current.identity == capture.handle.identity,
              current.session === capture.handle.session, controller.bindingID == capture.bindingID,
              IOSConflictCopyOrigin.sameLocation(current.location, capture.handle.location),
              let grant = controller.currentGrant, grant.workspaceID == capture.grant.workspaceID,
              grant.accessGeneration == capture.grant.accessGeneration, grant.scope == capture.grant.scope,
              IOSConflictCopyOrigin.exact(
                  grant.rootURL.path(percentEncoded: false),
                  capture.grant.rootURL.path(percentEncoded: false)
              ),
              let editor = controller.editor.captureSnapshot(), editor.bindingID == capture.bindingID,
              editor.revision.documentID == capture.handle.identity,
              editor.accessGeneration == capture.editorGeneration,
              !editor.hasMarkedText,
              IOSCopyOriginState(controller.documents.state(for: capture.handle.identity)) == capture.state
        else { throw IOSConflictCopyFailure.originChanged }
        guard editor.revision == capture.revision, current.session.version == capture.revision.version,
              current.session.isDirty == capture.isDirty,
              IOSConflictCopyOrigin.exact(current.session.text, capture.source),
              IOSConflictCopyOrigin.exact(editor.document.text, capture.source)
        else { throw IOSConflictCopyFailure.sourceChanged }
    }

    func validateDestination(_ grant: IOSWorkspaceGrant, lease: any IOSWorkspaceAccessLease) throws {
        guard !lease.isReleased, lease.grant.workspaceID == grant.workspaceID,
              lease.grant.accessGeneration == grant.accessGeneration, lease.grant.scope == .directory,
              IOSConflictCopyOrigin.exact(
                  lease.grant.rootURL.path(percentEncoded: false),
                  grant.rootURL.path(percentEncoded: false)
              )
        else { throw IOSConflictCopyFailure.destinationChanged }
        // A retained lease is a drain obligation, not proof that its generation
        // is still authorized. Ask the same service for a fresh synchronous proof.
        let proof = try controller.workspace.acquireLease(for: grant)
        proof.release()
    }

    func queueTerminal(_ outcome: IOSConflictCopyOutcome) {
        lastOutcome = outcome
        pendingTerminalNotice = IOSConflictCopyFeedback.notice(
            for: outcome, sourceUnavailable: origin?.state.isUnavailable == true
        )
    }
}
