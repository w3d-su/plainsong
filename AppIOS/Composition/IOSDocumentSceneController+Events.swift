import EditorKitIOS
import Foundation
import MarkdownCore
import PreviewKitContracts
import WorkspaceCore
import WorkspaceKitIOS

extension IOSDocumentSceneController {
    func publish() {
        let value = snapshot
        for observer in Array(observers.values) {
            observer.handler?(value)
        }
    }

    func updateEditorAccess() {
        guard let handle, let bindingID, let state = documents.state(for: handle.identity) else { return }
        let retainedGeneration = editor.captureSnapshot().flatMap {
            $0.bindingID == bindingID ? $0.accessGeneration : nil
        } ?? state.accessGeneration
        let generation = grantIsCurrent ? state.accessGeneration : max(state.accessGeneration, retainedGeneration)
        editor.updateAccess(
            for: handle.identity, bindingID: bindingID, generation: generation,
            canWrite: state.canWrite && !transitioning && !isShuttingDown && grantIsCurrent &&
                currentGrant?.workspaceID == handle.location.workspaceID &&
                currentGrant?.accessGeneration == state.accessGeneration
        )
        if grantIsCurrent {
            reloadRelay.attach(
                documentID: handle.identity,
                bindingID: bindingID,
                accessGeneration: state.accessGeneration
            )
        } else {
            reloadRelay.detach()
        }
    }

    func documentEvent(_ event: IOSDocumentEvent) {
        guard let identity = handle?.identity else { return }
        switch event {
        case let .stateChanged(documentID, _, _) where documentID == identity:
            updateEditorAccess()
            publish()
        case let .snapshotChanged(value) where value.revision.documentID == identity:
            updateEditorAccess()
            publish()
            requestRender()
        case let .saveCompleted(receipt) where receipt.revision.documentID == identity:
            // Source and saved baseline are already reconciled by UIDocumentStore.
            // Never install savedText into the native editor, even for an old save.
            publish()
        case let .failed(documentID, _, _) where documentID == identity:
            updateEditorAccess()
            publish()
        case let .closed(documentID) where documentID == identity && !transitioning:
            clearInstallation()
            publish()
        default: break
        }
    }

    func workspaceEvent(_ event: IOSWorkspaceEvent) {
        guard let grant = currentGrant else { return }
        switch event {
        case let .snapshotChanged(value) where value.workspaceID == grant.workspaceID &&
            value.accessGeneration == grant.accessGeneration:
            workspaceSnapshot = value
            publish()
        case let .invalidated(identity, generation) where identity == grant.workspaceID:
            grantIsCurrent = false
            renderTask?.cancel()
            workspaceSnapshot = nil
            if let handle, let bindingID {
                editor.updateAccess(for: handle.identity, bindingID: bindingID, generation: generation, canWrite: false)
                reloadRelay.detach()
                preview.render(handle.session.snapshot, identity: handle.identity, assetAccess: nil)
            }
            unavailableReason = "File access changed. Select the file or folder again."
            publish()
        case let .unavailable(identity, _) where identity == grant.workspaceID:
            unavailableReason = "The selected file provider is unavailable. Your edits are retained."
            publish()
        default: break
        }
    }

    func requestRender(immediate: Bool = false) {
        guard let handle, let bindingID else { return }
        let revision = IOSDocumentRevision(documentID: handle.identity, version: handle.session.version)
        guard renderedRevision != revision || immediate else { return }
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            if !immediate {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            }
            guard !Task.isCancelled, let self, self.handle?.identity == handle.identity,
                  self.bindingID == bindingID, handle.session.version == revision.version else { return }
            let context = grantIsCurrent ? currentGrant
                .flatMap { $0.scope == .directory ? assetContext($0) : nil } : nil
            renderedRevision = revision
            preview.render(handle.session.snapshot, identity: handle.identity, assetAccess: context)
        }
    }

    func previewEvent(_ event: IOSPreviewEvent) {
        switch event {
        case .ready:
            requestRender(immediate: true)
        case let .relativeLinkRequested(identity, href) where identity == handle?.identity:
            guard let base = handle?.location.fileURL,
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  let originBinding = bindingID else { return }
            Task { @MainActor [weak self] in
                guard let self, handle?.identity == identity, bindingID == originBinding else { return }
                do { try await openSelectedURL(url, scope: .singleFile) }
                catch {
                    // Navigation failure is a presentation error. It cannot
                    // revoke the current writer or overwrite a real access error.
                    guard handle == nil || (handle?.identity == identity && bindingID == originBinding) else { return }
                    onNavigationFailure?("The linked document could not be opened.")
                }
            }
        case let .checkboxRequested(revision, _, line, checked):
            applyPreviewCheckbox(revision: revision, line: line, checked: checked)
        case let .externalLinkRequested(url):
            if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                openExternalURL?(url)
            }
        default: break
        }
    }
}
