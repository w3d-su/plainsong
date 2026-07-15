import AppKit
import MarkdownCore
import STTextView
import SwiftUI

@MainActor
struct EditorInstalledDocumentState {
    private var textBinding: Binding<String>
    private var selectionBinding: Binding<NSRange?>
    private var documentBinding: EditorDocumentBindingRegistration?
    private var sourceSnapshot: EditorDocumentSourceSnapshot?
    private(set) var identity: EditorDocumentIdentity?
    private(set) var isInstalled = false
    private var nextCandidateGeneration: UInt64 = 0
    private(set) var preparedCandidateGeneration: UInt64?
    private(set) var installedCandidateGeneration: UInt64?

    init(text: Binding<String>, selection: Binding<NSRange?>) {
        textBinding = text
        selectionBinding = selection
    }

    var text: String {
        get { textBinding.wrappedValue }
        set { textBinding.wrappedValue = newValue }
    }

    var selection: NSRange? {
        get { selectionBinding.wrappedValue }
        set { selectionBinding.wrappedValue = newValue }
    }

    var isPreparedCandidateInstalled: Bool {
        isInstalled && preparedCandidateGeneration == installedCandidateGeneration
    }

    var installedSourceSnapshot: EditorDocumentSourceSnapshot? {
        sourceSnapshot
    }

    var hasSourceContract: Bool {
        documentBinding?.sourceContract != nil
    }

    mutating func prepare(
        text: Binding<String>,
        selection: Binding<NSRange?>,
        documentIdentity: EditorDocumentIdentity?,
        documentBindingID: EditorDocumentBindingID?,
        onDocumentBindingLifecycle: ((EditorDocumentBindingLifecycleEvent) -> Void)?,
        documentSourceContract: EditorDocumentSourceContract?,
        navigationCommand: EditorNavigationCommand?
    ) -> EditorDocumentTransitionCandidate {
        nextCandidateGeneration += 1
        preparedCandidateGeneration = nextCandidateGeneration

        // Before the first installation there is no live document to protect. Once
        // installed, bindings change only in `install`, after exact text validation.
        if !isInstalled {
            textBinding = text
            selectionBinding = selection
        }

        let documentBinding: EditorDocumentBindingRegistration? = if let documentSourceContract {
            EditorDocumentBindingRegistration(
                id: documentSourceContract.bindingID,
                lifecycle: documentSourceContract.lifecycle,
                sourceContract: documentSourceContract
            )
        } else if let documentBindingID, let onDocumentBindingLifecycle {
            EditorDocumentBindingRegistration(
                id: documentBindingID,
                lifecycle: onDocumentBindingLifecycle,
                sourceContract: nil
            )
        } else {
            nil
        }
        let preparedSourceSnapshot = documentSourceContract?.snapshot()
        let preparedSource = preparedSourceSnapshot?.source ?? text.wrappedValue

        return EditorDocumentTransitionCandidate(
            generation: nextCandidateGeneration,
            sourceText: preparedSource,
            sourceSnapshot: preparedSourceSnapshot,
            requestedSelection: selection.wrappedValue,
            navigationCommand: navigationCommand,
            text: text,
            selection: selection,
            documentIdentity: documentIdentity,
            documentBinding: documentBinding
        )
    }

    mutating func install(
        _ candidate: EditorDocumentTransitionCandidate
    ) -> (EditorDocumentInstallation, EditorDocumentBindingTransition) {
        let previousBinding = documentBinding
        textBinding = candidate.text
        selectionBinding = candidate.selection
        identity = candidate.documentIdentity
        documentBinding = candidate.documentBinding
        sourceSnapshot = candidate.sourceSnapshot
        isInstalled = true
        installedCandidateGeneration = candidate.generation
        let bindingChanged = previousBinding?.id != candidate.documentBinding?.id
        return (
            EditorDocumentInstallation(generation: candidate.generation),
            EditorDocumentBindingTransition(
                revoked: bindingChanged ? previousBinding : nil,
                installed: bindingChanged ? candidate.documentBinding : nil
            )
        )
    }

    mutating func revokeDocumentBinding() -> EditorDocumentBindingRegistration? {
        defer {
            documentBinding = nil
            sourceSnapshot = nil
        }
        return documentBinding
    }

    func requestWriterActivation(
        installationID: EditorDocumentBindingInstallationID
    ) -> EditorDocumentWriterEventResult? {
        guard let documentBinding,
              let sourceContract = documentBinding.sourceContract,
              let sourceSnapshot
        else {
            return nil
        }
        return sourceContract.writer(.activate(
            EditorDocumentBindingInstallation(
                bindingID: documentBinding.id,
                installationID: installationID
            ),
            from: sourceSnapshot
        ))
    }

    func publishSource(
        _ source: String,
        installationID: EditorDocumentBindingInstallationID
    ) -> EditorDocumentSourcePublicationResult? {
        guard let documentBinding,
              let sourceContract = documentBinding.sourceContract,
              let sourceSnapshot
        else {
            return nil
        }
        return sourceContract.publish(EditorDocumentSourcePublication(
            installation: EditorDocumentBindingInstallation(
                bindingID: documentBinding.id,
                installationID: installationID
            ),
            base: sourceSnapshot,
            source: source
        ))
    }

    mutating func acceptSourceSnapshot(_ snapshot: EditorDocumentSourceSnapshot) {
        sourceSnapshot = snapshot
        textBinding.wrappedValue = snapshot.source
    }

    mutating func synchronizeSourceSnapshot(_ snapshot: EditorDocumentSourceSnapshot) {
        sourceSnapshot = snapshot
    }

    mutating func refreshSourceSnapshot() {
        guard let snapshot = documentBinding?.sourceContract?.snapshot() else { return }
        sourceSnapshot = snapshot
    }

    func isSourceRevisionCurrent() -> Bool {
        guard let sourceSnapshot,
              let currentSnapshot = documentBinding?.sourceContract?.snapshot()
        else {
            return true
        }
        return sourceSnapshot.revision == currentSnapshot.revision
    }

    func canProveCurrentSource(
        for candidate: EditorDocumentTransitionCandidate
    ) -> Bool {
        guard isInstalled,
              documentBinding?.id == candidate.documentBinding?.id,
              let sourceSnapshot,
              let candidateSnapshot = candidate.sourceSnapshot
        else {
            return false
        }
        return sourceSnapshot.revision == candidateSnapshot.revision
    }

    func reportPendingSource(
        _ event: (EditorDocumentBindingInstallation) -> EditorDocumentPendingSourceEvent,
        installationID: EditorDocumentBindingInstallationID
    ) {
        guard let documentBinding,
              let sourceContract = documentBinding.sourceContract
        else {
            return
        }
        sourceContract.pendingSource(event(EditorDocumentBindingInstallation(
            bindingID: documentBinding.id,
            installationID: installationID
        )))
    }

    func releaseWriter(installationID: EditorDocumentBindingInstallationID) {
        guard let documentBinding,
              let sourceContract = documentBinding.sourceContract
        else {
            return
        }
        _ = sourceContract.writer(.release(EditorDocumentBindingInstallation(
            bindingID: documentBinding.id,
            installationID: installationID
        )))
    }

    func recordFullSourceComparison(_ kind: EditorDocumentSourceFullComparisonKind) {
        documentBinding?.sourceContract?.recordFullSourceComparison(kind)
    }
}

@MainActor
final class MarkdownTextViewCoordinator: @preconcurrency STTextViewDelegate {
    typealias DeferredDocumentTransitionInstallationHandler = (
        MarkdownTextViewCoordinator,
        EditorDocumentTransitionCandidate,
        MarkdownSTTextView
    ) -> Void

    let documentBindingInstallationID = EditorDocumentBindingInstallationID()
    var installedDocument: EditorInstalledDocumentState
    var text: String {
        get { installedDocument.text }
        set { installedDocument.text = newValue }
    }

    var selection: NSRange? {
        get { installedDocument.selection }
        set { installedDocument.selection = newValue }
    }

    var isUpdating = false
    var isUserEditing = false
    var lastAppliedHighlightRevision: Int?
    var currentDocumentIdentity: EditorDocumentIdentity? {
        installedDocument.identity
    }

    var currentInstalledSourceSnapshot: EditorDocumentSourceSnapshot? {
        installedDocument.installedSourceSnapshot
    }

    var preparedDocumentTransitionGeneration: UInt64? {
        installedDocument.preparedCandidateGeneration
    }

    var navigationState = EditorNavigationStateMachine()
    var navigationRetryTask: Task<Void, Never>?
    var navigationInputDeferralTask: Task<Void, Never>?
    var isApplyingNavigation = false
    private(set) var lastHandledFocusRequestID: Int?
    private(set) var pendingFocusRequestID: Int?
    private weak var pendingFocusTextView: STTextView?
    private var focusRetryTask: Task<Void, Never>?
    var scrollProxy: EditorScrollProxy?
    var commandProxy: EditorCommandProxy?
    let editingBehaviorGuard = EditingBehaviorGuard()
    var writerAuthorizedTextMutationDepth = 0
    weak var writerAuthorizedTextView: STTextView?
    var completionWorkspace: CompletionWorkspace = .empty
    var imageAssetInserter: EditorImageAssetInserter?
    var imageAssetContextID: String?
    var imageAssetInsertionGeneration: UInt64 = 0
    let imageThumbnailPresentationController = WYSIWYGImagePresentationController()
    var recentCompletionIDs: [String] = []
    var completionRequestID = 0
    var completionTask: Task<[Completion], Never>?
    weak var visibleRangeTextView: STTextView?
    var visibleRangeObserver: CoordinatorNotificationObserver?
    var visibleRangeChangeHandler: ((NSRange) -> Void)?
    var lastVisibleTextRange: NSRange?
    var isSourceSynchronizationPending = false
    var asynchronousTextMutationLeaseCount = 0
    var isNativeSourceSynchronized = true
    private var preparedNativeSourceCandidateGeneration: UInt64?
    private var deferredDocumentTransitionCandidate: EditorDocumentTransitionCandidate?
    private weak var deferredDocumentTransitionTextView: MarkdownSTTextView?
    private var deferredDocumentTransitionRetryTask: Task<Void, Never>?
    private var deferredDocumentTransitionInstallationHandler:
        DeferredDocumentTransitionInstallationHandler?

    var hasPendingWriterLease: Bool {
        isSourceSynchronizationPending || asynchronousTextMutationLeaseCount > 0
    }

    init(text: Binding<String>, selection: Binding<NSRange?>) {
        installedDocument = EditorInstalledDocumentState(text: text, selection: selection)
    }

    func canProveCurrentInstalledSource(
        for candidate: EditorDocumentTransitionCandidate
    ) -> Bool {
        isNativeSourceSynchronized &&
            !hasPendingWriterLease &&
            installedDocument.canProveCurrentSource(for: candidate)
    }

    func canProveCurrentInstalledSource() -> Bool {
        installedDocument.hasSourceContract &&
            isNativeSourceSynchronized &&
            !hasPendingWriterLease &&
            installedDocument.isSourceRevisionCurrent()
    }

    func nativeTextMatches(
        _ textView: STTextView,
        _ source: String,
        recordingFor candidate: EditorDocumentTransitionCandidate? = nil
    ) -> Bool {
        if let candidate {
            candidate.recordFullSourceComparison(.nativeView)
        } else {
            installedDocument.recordFullSourceComparison(.nativeView)
        }
        return MarkdownTextView.plainTextMatches(textView, source)
    }

    func nativeSourceStringMatches(_ nativeSource: String, _ appSource: String) -> Bool {
        installedDocument.recordFullSourceComparison(.nativeView)
        return ExactUTF16Text.matches(nativeSource, appSource)
    }

    func notePreparedNativeSource(_ candidate: EditorDocumentTransitionCandidate) {
        preparedNativeSourceCandidateGeneration = candidate.generation
    }

    func prepareDocumentTransition(
        text: Binding<String>,
        selection: Binding<NSRange?>,
        documentIdentity: EditorDocumentIdentity?,
        documentBindingID: EditorDocumentBindingID? = nil,
        onDocumentBindingLifecycle: ((EditorDocumentBindingLifecycleEvent) -> Void)? = nil,
        documentSourceContract: EditorDocumentSourceContract? = nil,
        navigationCommand: EditorNavigationCommand?,
        in textView: STTextView
    ) -> EditorDocumentTransitionCandidate {
        observeNavigationCommand(navigationCommand)
        supersedeDeferredDocumentTransition()

        let candidate = installedDocument.prepare(
            text: text,
            selection: selection,
            documentIdentity: documentIdentity,
            documentBindingID: documentBindingID,
            onDocumentBindingLifecycle: onDocumentBindingLifecycle,
            documentSourceContract: documentSourceContract,
            navigationCommand: navigationCommand
        )

        guard installedDocument.isInstalled,
              !hasPendingWriterLease,
              !textView.hasMarkedText()
        else {
            return candidate
        }

        // Equal App-owned binding/revision plus a synchronized native buffer is the
        // constant-time proof for an ordinary same-document SwiftUI update. A
        // different candidate must take the stale/recovery path below, where the
        // literal native comparison is instrumented before installation.
        if !canProveCurrentInstalledSource(for: candidate) {
            isUserEditing = false
        }
        return candidate
    }

    @discardableResult
    func finishDocumentTransition(
        _ candidate: EditorDocumentTransitionCandidate,
        in textView: STTextView
    ) -> EditorDocumentInstallation? {
        guard candidate.generation == installedDocument.preparedCandidateGeneration else {
            return nil
        }

        let isDeferredByInput = hasPendingWriterLease || textView.hasMarkedText()
        let isExactCandidateInstalled = canProveCurrentInstalledSource(for: candidate) ||
            preparedNativeSourceCandidateGeneration == candidate.generation
        guard !isDeferredByInput else {
            if isDeferredByInput,
               let textView = textView as? MarkdownSTTextView
            {
                deferredDocumentTransitionCandidate = candidate
                deferredDocumentTransitionTextView = textView
            }
            return nil
        }
        guard isExactCandidateInstalled || nativeTextMatches(
            textView,
            candidate.sourceText,
            recordingFor: candidate
        ) else {
            return nil
        }

        clearDeferredDocumentTransition()
        preparedNativeSourceCandidateGeneration = nil
        let (installation, bindingTransition) = installedDocument.install(candidate)
        isNativeSourceSynchronized = true
        bindingTransition.notify(installationID: documentBindingInstallationID)
        bindingTransition.updateSourceSynchronizers(
            installationID: documentBindingInstallationID
        ) { [weak self, weak textView] snapshot in
            guard let self, let textView else { return false }
            return synchronizeInstalledSource(snapshot, in: textView)
        }
        cancelPendingNavigationTasks()
        return installation
    }

    func revokeInstalledDocumentBinding() {
        cancelDeferredDocumentTransition()
        imageAssetInsertionGeneration &+= 1
        if hasPendingWriterLease {
            installedDocument.reportPendingSource(
                EditorDocumentPendingSourceEvent.abandoned,
                installationID: documentBindingInstallationID
            )
            isSourceSynchronizationPending = false
            asynchronousTextMutationLeaseCount = 0
        }
        installedDocument.releaseWriter(installationID: documentBindingInstallationID)
        guard let registration = installedDocument.revokeDocumentBinding() else { return }
        registration.sourceContract?.unregisterSourceSynchronizer(
            EditorDocumentBindingInstallation(
                bindingID: registration.id,
                installationID: documentBindingInstallationID
            )
        )
        registration.lifecycle(.revoked(EditorDocumentBindingInstallation(
            bindingID: registration.id,
            installationID: documentBindingInstallationID
        )))
    }

    var isPreparedDocumentInstalled: Bool {
        installedDocument.isPreparedCandidateInstalled
    }

    func setDeferredDocumentTransitionInstallationHandler(
        _ handler: @escaping DeferredDocumentTransitionInstallationHandler
    ) {
        deferredDocumentTransitionInstallationHandler = handler
    }

    func cancelDeferredDocumentTransition() {
        clearDeferredDocumentTransition()
    }

    func detachDeferredDocumentTransitionInstallationHandler() {
        clearDeferredDocumentTransition()
        deferredDocumentTransitionInstallationHandler = nil
    }

    private func supersedeDeferredDocumentTransition() {
        clearDeferredDocumentTransition()
    }

    private func clearDeferredDocumentTransition() {
        deferredDocumentTransitionRetryTask?.cancel()
        deferredDocumentTransitionRetryTask = nil
        deferredDocumentTransitionCandidate = nil
        deferredDocumentTransitionTextView = nil
    }

    func scheduleDeferredDocumentTransitionRetry() {
        guard deferredDocumentTransitionCandidate != nil,
              let textView = deferredDocumentTransitionTextView
        else {
            return
        }

        deferredDocumentTransitionRetryTask?.cancel()
        deferredDocumentTransitionRetryTask = Task { @MainActor [weak self, weak textView] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  let textView
            else {
                return
            }
            deferredDocumentTransitionRetryTask = nil
            retryDeferredDocumentTransitionIfPossible(in: textView)
        }
    }

    private func retryDeferredDocumentTransitionIfPossible(
        in textView: MarkdownSTTextView
    ) {
        guard let retainedCandidate = deferredDocumentTransitionCandidate,
              deferredDocumentTransitionTextView === textView,
              retainedCandidate.generation == installedDocument.preparedCandidateGeneration,
              !hasPendingWriterLease,
              !textView.hasMarkedText()
        else {
            return
        }
        let candidate = retainedCandidate.refreshingSourceSnapshotForRetry()

        // The old document must be fully published to its still-installed binding before
        // replacing any view state with the destination candidate.
        _ = syncTextFromTextViewIfNeeded(textView)
        guard !hasPendingWriterLease,
              !textView.hasMarkedText()
        else {
            return
        }
        guard canProveCurrentInstalledSource() || nativeTextMatches(textView, text) else {
            assertionFailure("Old document source did not settle before deferred transition retry")
            cancelDeferredDocumentTransition()
            return
        }

        let previousSelection = textView.selectedRange()
        isUpdating = true
        textView.text = candidate.sourceText
        textView.textSelection = previousSelection.clamped(
            toLength: (candidate.sourceText as NSString).length
        )
        isUpdating = false
        notePreparedNativeSource(candidate)

        guard finishDocumentTransition(candidate, in: textView) != nil else {
            return
        }

        if let deferredDocumentTransitionInstallationHandler {
            deferredDocumentTransitionInstallationHandler(self, candidate, textView)
        } else {
            if let requestedSelection = candidate.requestedSelection {
                textView.textSelection = requestedSelection.clamped(
                    toLength: (candidate.sourceText as NSString).length
                )
                selection = textView.selectedRange()
            }
            applyPendingNavigationIfPossible(in: textView)
        }
        isUserEditing = false
    }
}

extension MarkdownTextViewCoordinator {
    func attachFocusHandler(to textView: MarkdownSTTextView) {
        textView.windowAttachmentHandler = { [weak self, weak textView] _ in
            guard let self, let textView else { return }
            focusPendingRequestIfPossible(in: textView)
            applyPendingNavigationIfPossible(in: textView)
        }
    }

    func detachFocusHandler(from textView: MarkdownSTTextView) {
        textView.windowAttachmentHandler = nil
        if pendingFocusTextView === textView {
            cancelPendingFocusRequest()
        }
        cancelPendingNavigationTasks()
    }

    func cancelPendingFocusRequest() {
        focusRetryTask?.cancel()
        focusRetryTask = nil
        pendingFocusRequestID = nil
        pendingFocusTextView = nil
    }

    func focusIfNeeded(_ requestID: Int, textView: STTextView) {
        guard requestID > 0,
              lastHandledFocusRequestID != requestID
        else {
            return
        }

        if focus(requestID, textView: textView) {
            cancelPendingFocusRequest()
            return
        }

        pendingFocusRequestID = requestID
        pendingFocusTextView = textView
        scheduleFocusRetry(for: requestID, textView: textView)
    }

    private func scheduleFocusRetry(for requestID: Int, textView: STTextView) {
        focusRetryTask?.cancel()
        focusRetryTask = Task { @MainActor [weak self, weak textView] in
            for _ in 0 ..< 60 {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }

                guard let self, let textView else {
                    return
                }
                if pendingFocusRequestID != requestID {
                    return
                }
                if focusPendingRequestIfPossible(in: textView) {
                    return
                }
            }
        }
    }

    @discardableResult
    private func focusPendingRequestIfPossible(in textView: STTextView) -> Bool {
        guard let requestID = pendingFocusRequestID,
              pendingFocusTextView === textView
        else {
            return false
        }

        if focus(requestID, textView: textView) {
            cancelPendingFocusRequest()
            return true
        }

        return false
    }

    @discardableResult
    private func focus(_ requestID: Int, textView: STTextView) -> Bool {
        guard textView.acceptsFirstResponder,
              let window = textView.window
        else {
            return false
        }

        ensureInsertionPointIfNeeded(in: textView)

        guard window.firstResponder !== textView else {
            lastHandledFocusRequestID = requestID
            return true
        }

        guard window.makeFirstResponder(textView) else {
            return false
        }

        lastHandledFocusRequestID = requestID
        return true
    }

    private func ensureInsertionPointIfNeeded(in textView: STTextView) {
        guard textView.selectedRange().location == NSNotFound else {
            return
        }

        textView.textSelection = NSRange(location: 0, length: 0)
    }

    func textViewWillChangeText(_ notification: Notification) {
        guard !isUpdating else {
            return
        }

        if let textView = notification.object as? MarkdownSTTextView {
            textView.capturePotentialMarkedTextReplacementRange(textView.selectedRange())
        }
        isNativeSourceSynchronized = false
        isUserEditing = true
    }

    func textViewDidChangeText(_ notification: Notification) {
        guard !isUpdating, let textView = notification.object as? STTextView else {
            return
        }

        isUserEditing = true
        syncTextFromTextViewIfNeeded(textView)
        if let textView = textView as? MarkdownSTTextView {
            imageThumbnailPresentationController.documentTextDidChange(in: textView)
            textView.clearPotentialMarkedTextReplacementRangeIfUnmarked()
            scheduleMarkedTextReplacementRangeCleanup(for: textView)
        }
        reportVisibleRangeIfNeeded(in: textView)
        schedulePendingNavigationAfterInput(in: textView)
    }

    func textView(
        _ textView: STTextView,
        willChangeTextIn affectedCharRange: NSTextRange,
        replacementString _: String
    ) {
        guard !isUpdating,
              let textView = textView as? MarkdownSTTextView
        else {
            return
        }
        textView.confirmPotentialMarkedTextReplacementRange(NSRange(
            affectedCharRange,
            in: textView.textContentManager
        ))
    }

    func textView(
        _ textView: STTextView,
        shouldChangeTextIn affectedCharRange: NSTextRange,
        replacementString: String?
    ) -> Bool {
        if !isUpdating, editingBehaviorGuard.isApplying {
            // EditingBehaviorGuard alone is not writer proof. Only a coordinator path
            // that completed preflight may authorize this re-entrant replacement.
            guard writerAuthorizedTextMutationDepth > 0,
                  writerAuthorizedTextView === textView
            else {
                (textView as? MarkdownSTTextView)?
                    .discardUnconfirmedMarkedTextReplacementRange()
                return false
            }
            isUserEditing = true
            return true
        }

        let fileKind = commandProxy?.currentFileKind() ?? .markdown
        let selection = NSRange(affectedCharRange, in: textView.textContentManager)
        if let textView = textView as? MarkdownSTTextView {
            textView.capturePotentialMarkedTextReplacementRange(selection)
        }
        let shouldTriggerCompletion = replacementString.map {
            EditorCompletionSupport.shouldTriggerCompletion(
                replacementString: $0,
                emojiShortcodePrefixBeforeChange: EditorCompletionSupport.emojiShortcodePrefixBeforeSelection(
                    in: textView,
                    selection: selection
                ),
                fileKind: fileKind
            )
        } ?? false
        let proposedBehavior = EditingBehaviorsSupport.proposedChange(
            in: textView,
            affectedRange: affectedCharRange,
            replacementString: replacementString,
            fileKind: fileKind,
            editingGuard: editingBehaviorGuard
        )

        if case .selectionOnly = proposedBehavior {
            // Skip-over is selection-only. It must not enter the native-source
            // publication state machine or acquire source mutation authority.
            (textView as? MarkdownSTTextView)?
                .discardUnconfirmedMarkedTextReplacementRange()
            return EditingBehaviorsSupport.apply(
                proposedBehavior,
                to: textView,
                editingGuard: editingBehaviorGuard
            )
        }

        if !isUpdating {
            guard preflightTextMutation(
                in: textView,
                allowsPendingStalePublication: true
            ) else {
                (textView as? MarkdownSTTextView)?
                    .discardUnconfirmedMarkedTextReplacementRange()
                return false
            }
            isUserEditing = true
        }

        let shouldAllowNativeInput = applyPreflightedEditingBehavior(
            proposedBehavior,
            to: textView
        )

        if shouldTriggerCompletion {
            requestCompletion(afterApplyingChangeIn: textView)
        }

        if !shouldAllowNativeInput {
            (textView as? MarkdownSTTextView)?
                .discardUnconfirmedMarkedTextReplacementRange()
        }

        return shouldAllowNativeInput
    }

    func textView(
        _ textView: STTextView,
        didChangeTextIn _: NSTextRange,
        replacementString _: String
    ) {
        guard !isUpdating else {
            return
        }

        isUserEditing = true
        syncTextFromTextViewIfNeeded(textView)
        if let textView = textView as? MarkdownSTTextView {
            imageThumbnailPresentationController.documentTextDidChange(in: textView)
            textView.clearPotentialMarkedTextReplacementRangeIfUnmarked()
            scheduleMarkedTextReplacementRangeCleanup(for: textView)
        }
        schedulePendingNavigationAfterInput(in: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isUpdating, let textView = notification.object as? STTextView else {
            return
        }

        if syncTextFromTextViewIfNeeded(textView) {
            isUserEditing = true
            if let textView = textView as? MarkdownSTTextView {
                imageThumbnailPresentationController.documentTextDidChange(in: textView)
            }
        }
        (textView as? MarkdownSTTextView)?
            .clearPotentialMarkedTextReplacementRangeIfUnmarked()
        if let textView = textView as? MarkdownSTTextView {
            scheduleMarkedTextReplacementRangeCleanup(for: textView)
        }
        selection = textView.selectedRange()
        scrollProxy?.emitVisibleLine(containingUTF16Offset: textView.selectedRange().location, in: textView)
        reportVisibleRangeIfNeeded(in: textView)
        schedulePendingNavigationAfterInput(in: textView)
    }

    @discardableResult
    private func syncTextFromTextViewIfNeeded(_ textView: STTextView) -> Bool {
        if shouldDeferTextSync(from: textView) {
            isNativeSourceSynchronized = false
            beginSourceSynchronizationPending()
            return false
        }
        if installedDocument.hasSourceContract,
           isNativeSourceSynchronized,
           !isSourceSynchronizationPending
        {
            return false
        }

        // Keep the lazily bridged CFStorage string here. Eagerly transcoding a 1 MiB
        // buffer on every keystroke costs more than one frame; consumers that need a
        // contiguous UTF-8 view already run outside this synchronous native-input path.
        let newText = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        if !installedDocument.hasSourceContract,
           nativeSourceStringMatches(newText, text)
        {
            installedDocument.refreshSourceSnapshot()
            isNativeSourceSynchronized = true
            settleSourceSynchronizationPending()
            return false
        }
        guard let publicationResult = installedDocument.publishSource(
            newText,
            installationID: documentBindingInstallationID
        ) else {
            text = newText
            isNativeSourceSynchronized = true
            settleSourceSynchronizationPending()
            return true
        }

        switch publicationResult {
        case let .accepted(snapshot, sourceWasReconciled):
            if sourceWasReconciled,
               !nativeSourceStringMatches(newText, snapshot.source)
            {
                applyReconciledSource(snapshot.source, replacing: newText, in: textView)
            }
            installedDocument.acceptSourceSnapshot(snapshot)
            isNativeSourceSynchronized = true
            settleSourceSynchronizationPending()
            return true
        case let .rejected(snapshot):
            let didRestoreSource = !nativeTextMatches(
                textView,
                snapshot.source
            )
            if didRestoreSource {
                applyReconciledSource(snapshot.source, replacing: newText, in: textView)
            }
            installedDocument.synchronizeSourceSnapshot(snapshot)
            isNativeSourceSynchronized = true
            settleSourceSynchronizationPending()
            installedDocument.releaseWriter(
                installationID: documentBindingInstallationID
            )
            scheduleDeferredDocumentTransitionRetry()
            return didRestoreSource
        }
    }

    private func synchronizeInstalledSource(
        _ snapshot: EditorDocumentSourceSnapshot,
        in textView: STTextView
    ) -> Bool {
        guard !hasPendingWriterLease,
              !textView.hasMarkedText()
        else {
            return false
        }

        let selectedRange = textView.selectedRange()
        isUpdating = true
        textView.text = snapshot.source
        textView.textSelection = selectedRange.clamped(
            toLength: (snapshot.source as NSString).length
        )
        isUpdating = false
        installedDocument.acceptSourceSnapshot(snapshot)
        isNativeSourceSynchronized = true
        isUserEditing = false
        return true
    }

    private func shouldDeferTextSync(from textView: STTextView) -> Bool {
        if let textView = textView as? MarkdownSTTextView,
           textView.isSuppressingIntermediateMarkedTextRemoval
        {
            return true
        }

        return textView.hasMarkedText()
    }
}
