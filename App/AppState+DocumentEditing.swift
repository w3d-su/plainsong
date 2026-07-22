import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func replaceDocumentText(_ newText: String) {
        replaceDocumentText(newText, in: currentDocument)
    }

    func replaceDocumentText(_ newText: String, in session: DocumentSession) {
        guard session === currentDocument,
              !isExternalSourceMutationFenced(for: session),
              !ExactSourceText.matches(newText, session.text)
        else {
            return
        }

        applyDocumentText(newText, to: session)
    }

    func cancelStatisticsRefresh(for session: DocumentSession) {
        if session === currentDocument {
            statisticsTask?.cancel()
            statisticsTask = nil
        }
        let sessionIdentity = ObjectIdentifier(session)
        sessionStatisticsTasks[sessionIdentity]?.task.cancel()
        sessionStatisticsTasks[sessionIdentity] = nil
    }

    func applyDocumentText(_ newText: String, to session: DocumentSession) {
        let previousVersion = session.version
        session.replaceText(newText, refreshStatistics: false)
        scheduleDocumentTextSideEffects(
            for: session,
            shouldRefreshWorkspaceSearch: session.version != previousVersion
        )
    }

    func applyAuthorizedEditorText(_ newText: String, to session: DocumentSession) {
        let previousVersion = session.version
        session.replaceTextFromAuthorizedEditor(newText, refreshStatistics: false)
        scheduleDocumentTextSideEffects(
            for: session,
            shouldRefreshWorkspaceSearch: session.version != previousVersion
        )
    }

    private func scheduleDocumentTextSideEffects(
        for session: DocumentSession,
        shouldRefreshWorkspaceSearch: Bool
    ) {
        if let url = sessionStateURL(for: session) {
            sessionPolicy.updateDirtyState(for: url, isDirty: session.isDirty)
        }
        scheduleWorkspaceMutationTextRecovery(for: session)
        scheduleStatisticsRefresh(for: session)
        if session === currentDocument {
            scheduleCompletionWorkspaceRefresh(debounceNanoseconds: 250_000_000)
            scheduleAutosave()
        } else {
            scheduleAutosave(for: session)
        }
        if shouldRefreshWorkspaceSearch {
            cancelPendingEditorNavigationIfNeeded(targeting: session)
            restartActiveWorkspaceSearchAfterRelevantEdit(in: session)
        }
    }

    func setTaskCheckbox(line: Int, checked: Bool, version: Int) {
        guard version == currentDocument.version else { return }
        guard let lineRange = currentDocument.text.rangeOfOneBasedLine(line) else { return }

        let lineText = String(currentDocument.text[lineRange])
        guard let checkboxRange = Self.taskCheckboxStateRange(in: lineText) else { return }

        let desiredState = checked ? "x" : " "
        guard String(lineText[checkboxRange]) != desiredState else { return }

        var updatedLine = lineText
        updatedLine.replaceSubrange(checkboxRange, with: desiredState)

        var updatedText = currentDocument.text
        updatedText.replaceSubrange(lineRange, with: updatedLine)
        replaceDocumentText(updatedText)
    }

    func openPreviewLink(_ href: String) {
        guard !href.hasPrefix("#"),
              let baseURL = currentDocument.fileURL?.deletingLastPathComponent()
        else {
            return
        }

        let path = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? href
        let url = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
        guard FileKind(url: url) != nil else { return }

        let isWorkspaceLink = workspaceRootURL.map { Self.isDescendant(url, of: $0) } ?? false
        if isWorkspaceLink {
            openWorkspaceFile(url)
        } else {
            openExternalFile(url)
        }
    }

    var activeEditorDocumentIdentity: EditorDocumentIdentity? {
        editorDocumentIdentity(for: currentDocument)
    }

    func editorDocumentIdentity(for session: DocumentSession) -> EditorDocumentIdentity? {
        sessionStateURL(for: session).map {
            EditorDocumentIdentity(rawValue: $0.absoluteString)
        }
    }

    func activateWorkspaceSearchResult(
        context: WorkspaceSearchContext,
        fileResult: WorkspaceSearchFileResult,
        match: TextSearchMatch
    ) {
        guard isAcceptedWorkspaceSearchActivation(
            context: context,
            fileResult: fileResult,
            match: match
        ) else {
            return
        }

        guard let target = workspaceSearchActivationTarget(
            fileResult: fileResult,
            match: match
        )
        else {
            return
        }

        do {
            guard let activation = try prepareWorkspaceSearchActivation(
                target,
                fileResult: fileResult,
                match: match
            ) else {
                return
            }
            try workspaceSearchPostActivationHook?()
            cancelPendingEditorNavigationIfNeeded(force: true)
            commitWorkspaceSearchActivation(activation)
            issueEditorNavigation(
                documentIdentity: activation.documentIdentity,
                selection: match.range
            )
        } catch {
            present(error, title: "Could Not Open Search Result")
        }
    }

    private func prepareWorkspaceSearchActivation(
        _ target: WorkspaceSearchActivationTarget,
        fileResult: WorkspaceSearchFileResult,
        match: TextSearchMatch
    ) throws -> PreparedWorkspaceSearchActivation? {
        guard workspaceTree != nil,
              let rootAuthority = workspaceSearchRootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration,
              let fileAuthority = fileResult.fileAuthority,
              fileAuthority.location.rootAuthority == rootAuthority,
              fileAuthority.location == target.location,
              fileAuthority.identity == target.expectedIdentity,
              ExactSourceText.matches(
                  fileAuthority.location.relativePath,
                  fileResult.relativePath
              )
        else {
            return nil
        }

        let preparedRead = try prepareEditorImageAssetDocumentRead(
            fileStore: fileStore,
            at: target.location,
            expecting: target.expectedIdentity
        )
        let readResult = preparedRead.result
        let anchoredActivation = try prepareAnchoredFileSessionActivation(
            file: readResult.file,
            at: target.location,
            metadata: readResult.metadata,
            sha256Digest: readResult.sha256Digest,
            preparedImageAssetAuthority: preparedRead.preparedAuthority
        )
        var shouldFinishRejectedRetiredSession = switch anchoredActivation.source {
        case .retired:
            true
        case .cached, .loaded:
            false
        }
        defer {
            if shouldFinishRejectedRetiredSession {
                finishRetiredEditorDocumentSessionIfPossible(for: anchoredActivation.session)
            }
        }
        guard anchoredActivation.binding.identity == target.expectedIdentity else {
            return nil
        }
        if hasConflictingPhysicalSessionOwnership(
            target.expectedIdentity,
            excluding: anchoredActivation.session
        ) {
            accountForReusableWorkspaceSearchPhysicalOwnershipCollision(
                anchoredActivation
            )
            return nil
        }
        supersedeExternalWorkAfterReusableWorkspaceSearchObservation(
            anchoredActivation
        )
        guard reconcileReusableWorkspaceSearchObservation(anchoredActivation) else {
            return nil
        }

        let usesLoadedSource = workspaceSearchActivationUsesLoadedSource(anchoredActivation)
        let preparedText = usesLoadedSource
            ? anchoredActivation.file.text
            : anchoredActivation.session.text
        let activeFingerprint = WorkspaceSearchContentFingerprint(text: preparedText)
        guard activeFingerprint.sha256Digest == fileResult.contentFingerprint.sha256Digest,
              activeFingerprint.utf8ByteCount == fileResult.contentFingerprint.utf8ByteCount
        else {
            return nil
        }

        guard Self.isValidEditorRange(
            match.range,
            textUTF16Length: preparedText.utf16.count
        ) else {
            return nil
        }

        let activation = PreparedWorkspaceSearchActivation(
            nodeID: target.nodeID,
            anchoredActivation: anchoredActivation,
            documentIdentity: EditorDocumentIdentity(
                rawValue: target.location.fileURL.absoluteString
            )
        )
        shouldFinishRejectedRetiredSession = false
        return activation
    }

    /// A reusable session can still carry the disk proof from A while the coherent activation
    /// load observes C. Account for C before fingerprint/range validation can reject navigation:
    /// a clean session adopts C, while dirty or pending source retains A and records a conflict.
    private func reconcileReusableWorkspaceSearchObservation(
        _ activation: PreparedAnchoredFileSessionActivation
    ) -> Bool {
        switch activation.source {
        case .loaded:
            return true
        case .cached, .retired:
            let observation = ObservedRetainedFileVersion(
                location: activation.binding.location,
                file: activation.file,
                identity: activation.binding.identity,
                sha256Digest: activation.binding.sha256Digest
            )
            guard reconcileObservedRetainedFileVersion(
                observation,
                for: activation.session,
                canonicalURL: activation.canonicalURL
            ) else {
                return false
            }
            adoptAnchoredFileBinding(
                activation.binding,
                for: activation.session,
                preparedImageAssetAuthority: activation.preparedImageAssetAuthority
            )
            return true
        }
    }

    /// A successful coherent load is the disk ordering boundary even when the retained
    /// search result is rejected by a later fingerprint or range check. Retire older
    /// observation work exactly once here, before any such validation can return early.
    private func supersedeExternalWorkAfterReusableWorkspaceSearchObservation(
        _ activation: PreparedAnchoredFileSessionActivation
    ) {
        switch activation.source {
        case .cached, .retired:
            supersedeExternalWorkAfterWorkspaceSearchObservation(
                for: activation.session,
                canonicalURL: activation.canonicalURL
            )
        case .loaded:
            break
        }
    }

    /// A cached or retired B whose path now names an inode already owned by A cannot adopt
    /// that observation. Treat the replacement as B losing its retained namespace, then
    /// advance the disk-event fence so an older inspection cannot later restore stale state.
    /// A newly loaded candidate owns no reusable state and remains transactionally invisible.
    private func accountForReusableWorkspaceSearchPhysicalOwnershipCollision(
        _ activation: PreparedAnchoredFileSessionActivation
    ) {
        switch activation.source {
        case .cached, .retired:
            markSessionDetachedFromMissingFile(
                activation.session,
                url: activation.canonicalURL
            )
            supersedeExternalWorkAfterWorkspaceSearchObservation(
                for: activation.session,
                canonicalURL: activation.canonicalURL
            )
        case .loaded:
            break
        }
    }

    private func commitWorkspaceSearchActivation(_ activation: PreparedWorkspaceSearchActivation) {
        let prepared = activation.anchoredActivation
        let session = prepared.session
        let canonicalURL = prepared.canonicalURL
        let sessionIdentity = ObjectIdentifier(session)
        var reactivatedRetiredSession = false
        var shouldRestartRetiredInspection = false

        if case let .retired(retiredURL) = prepared.source {
            guard let retirement = retiredEditorDocumentSessions[retiredURL],
                  retirement.session === session
            else {
                preconditionFailure("Prepared retired search activation changed before commit")
            }
            reactivatedRetiredSession = true
            shouldRestartRetiredInspection = externalDiskInspectionTasks[sessionIdentity] != nil
            _ = advanceSessionLifecycle(for: session)
        }

        if session !== currentDocument {
            moveCurrentDocumentWorkToBackgroundForSearchActivation()
        }
        sessionCache[canonicalURL] = session

        switch prepared.source {
        case .loaded:
            session.reset(
                text: prepared.file.text,
                url: canonicalURL,
                fileKind: prepared.file.fileKind,
                isDirty: false
            )
            clearExternalChangeConflict(at: canonicalURL)
            detachedSessionURLs.remove(canonicalURL)
            adoptAnchoredFileBinding(
                prepared.binding,
                for: session,
                preparedImageAssetAuthority: prepared.preparedImageAssetAuthority
            )
            recordKnownSessionDiskText(
                prepared.file.text,
                for: session,
                canonicalURL: canonicalURL
            )
        case .cached, .retired:
            // Reusable observations were reconciled and, when accepted, adopted before
            // fingerprint/range validation. Commit only changes activation ownership here.
            break
        }

        if session !== currentDocument {
            setCurrentDocument(session, synchronizingWorkspaceTree: false)
        }
        handleSessionAccess(url: canonicalURL, isDirty: session.isDirty)

        if reactivatedRetiredSession {
            restoreRecoveryPrompt(for: session)
        }
        if shouldRestartRetiredInspection ||
            deferredExternalChangeResolutions[canonicalURL] != nil
        {
            handleExternalChange(for: session, advancingDiskEvent: false)
        }
        if reactivatedRetiredSession {
            finishRetiredEditorDocumentSessionIfPossible(for: session)
        }
        if var tree = workspaceTree {
            tree.selectNode(id: activation.nodeID)
            workspaceTree = tree
        }
    }

    private func moveCurrentDocumentWorkToBackgroundForSearchActivation() {
        let previousSession = currentDocument
        moveCurrentAutosaveToBackground(for: previousSession)
        moveCurrentStatisticsToBackground(for: previousSession)
    }

    private func isAcceptedWorkspaceSearchActivation(
        context: WorkspaceSearchContext,
        fileResult: WorkspaceSearchFileResult,
        match: TextSearchMatch
    ) -> Bool {
        guard isActiveWorkspaceSearchContext(context),
              let storedResult = workspaceSearchState.fileResults.first(where: {
                  ExactSourceText.matches($0.relativePath, fileResult.relativePath)
              }),
              storedResult == fileResult,
              storedResult.matches.contains(match)
        else {
            return false
        }
        return true
    }

    private func workspaceSearchActivationTarget(
        fileResult: WorkspaceSearchFileResult,
        match: TextSearchMatch
    ) -> WorkspaceSearchActivationTarget? {
        guard Self.isStructurallyValidEditorRange(match.range),
              let rootAuthority = workspaceSearchRootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration,
              let tree = workspaceTree,
              let node = firstNode(in: tree.root, relativePath: fileResult.relativePath),
              node.isEditableMarkdown,
              !hasConflictingWorkspaceTreeIdentity(
                  in: tree.root,
                  nodeID: node.id,
                  expectedRelativePath: fileResult.relativePath,
                  expectedMutationExpectation: node.mutationExpectation
              ),
              let fileAuthority = fileResult.fileAuthority,
              fileAuthority.location.rootAuthority == rootAuthority,
              ExactSourceText.matches(
                  fileAuthority.location.relativePath,
                  fileResult.relativePath
              )
        else {
            return nil
        }

        return WorkspaceSearchActivationTarget(
            location: fileAuthority.location,
            expectedIdentity: fileAuthority.identity,
            nodeID: node.id
        )
    }

    private func workspaceSearchActivationUsesLoadedSource(
        _ activation: PreparedAnchoredFileSessionActivation
    ) -> Bool {
        if case .loaded = activation.source {
            return true
        }
        let session = activation.session
        let sessionIdentity = ObjectIdentifier(session)
        let canonicalURL = activation.canonicalURL
        return !session.isDirty &&
            !hasPendingEditorSource(for: session) &&
            pendingExternalTexts[canonicalURL] == nil &&
            pendingExternalFileVersions[canonicalURL] == nil &&
            !detachedSessionURLs.contains(canonicalURL) &&
            indeterminateSessionWrites[sessionIdentity] == nil &&
            !indeterminateWorkspaceMutationSessions.contains(sessionIdentity)
    }

    private func hasConflictingWorkspaceTreeIdentity(
        in node: WorkspaceFileNode,
        nodeID: WorkspaceFileNode.ID,
        expectedRelativePath: String,
        expectedMutationExpectation: WorkspaceItemMutationExpectation?
    ) -> Bool {
        if !ExactSourceText.matches(node.relativePath, expectedRelativePath) {
            if node.id == nodeID {
                return true
            }
            if let expectedMutationExpectation,
               node.mutationExpectation == expectedMutationExpectation
            {
                return true
            }
        }
        return node.children.contains { child in
            hasConflictingWorkspaceTreeIdentity(
                in: child,
                nodeID: nodeID,
                expectedRelativePath: expectedRelativePath,
                expectedMutationExpectation: expectedMutationExpectation
            )
        }
    }

    func cancelPendingEditorNavigationIfNeeded(force: Bool = false) {
        if !force {
            guard let command = editorNavigationCommand,
                  case .navigate = command
            else {
                return
            }
        }

        editorNavigationCommand = .cancel(id: advanceEditorNavigationGeneration())
    }

    func cancelPendingEditorNavigationIfNeeded(targeting session: DocumentSession) {
        guard case let .navigate(request)? = editorNavigationCommand,
              let documentIdentity = editorDocumentIdentity(for: session),
              request.documentIdentity == documentIdentity
        else {
            return
        }

        editorNavigationCommand = .cancel(id: advanceEditorNavigationGeneration())
    }

    static func editorDocumentIdentity(for url: URL) -> EditorDocumentIdentity {
        EditorDocumentIdentity(rawValue: url.absoluteString)
    }

    static func editorDocumentIdentity(forCanonicalURL url: URL) -> EditorDocumentIdentity {
        EditorDocumentIdentity(rawValue: url.absoluteString)
    }

    private func issueEditorNavigation(
        documentIdentity: EditorDocumentIdentity,
        selection: NSRange
    ) {
        editorNavigationCommand = .navigate(EditorNavigationRequest(
            id: advanceEditorNavigationGeneration(),
            documentIdentity: documentIdentity,
            selection: selection
        ))
    }

    private func advanceEditorNavigationGeneration() -> UInt64 {
        precondition(editorNavigationGeneration < .max, "Editor navigation generation exhausted")
        editorNavigationGeneration += 1
        return editorNavigationGeneration
    }

    private static func isStructurallyValidEditorRange(_ range: NSRange) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.length <= Int.max - range.location
    }

    private static func isValidEditorRange(_ range: NSRange, textUTF16Length: Int) -> Bool {
        guard textUTF16Length >= 0,
              isStructurallyValidEditorRange(range),
              range.location <= textUTF16Length
        else {
            return false
        }

        return range.length <= textUTF16Length - range.location
    }

    func moveCurrentStatisticsToBackground(for session: DocumentSession) {
        guard session === currentDocument else { return }
        let shouldReschedule = statisticsTask != nil
        statisticsTask?.cancel()
        statisticsTask = nil
        guard shouldReschedule else { return }
        scheduleBackgroundStatisticsRefresh(for: session)
    }

    private func scheduleStatisticsRefresh(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        if session === currentDocument {
            sessionStatisticsTasks[sessionIdentity]?.task.cancel()
            sessionStatisticsTasks[sessionIdentity] = nil
            statisticsTask?.cancel()
            statisticsTask = makeStatisticsTask(for: session)
            return
        }

        scheduleBackgroundStatisticsRefresh(for: session)
    }

    private func scheduleBackgroundStatisticsRefresh(for session: DocumentSession) {
        let sessionIdentity = ObjectIdentifier(session)
        sessionStatisticsTasks[sessionIdentity]?.task.cancel()
        let token = UUID()
        let task = makeStatisticsTask(for: session) { [weak self] in
            guard let self,
                  sessionStatisticsTasks[sessionIdentity]?.token == token
            else {
                return
            }
            sessionStatisticsTasks[sessionIdentity] = nil
        }
        sessionStatisticsTasks[sessionIdentity] = SessionBackgroundTask(token: token, task: task)
    }

    private func makeStatisticsTask(
        for session: DocumentSession,
        onCompletion: (@MainActor () -> Void)? = nil
    ) -> Task<Void, Never> {
        Task { @MainActor [weak session] in
            defer { onCompletion?() }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard let session, !Task.isCancelled else { return }

            // Counting a large document is O(n); keep it off the main thread.
            let text = session.text
            let revision = session.version
            let statistics = await Task.detached(priority: .utility) {
                TextStatistics(text: text)
            }.value

            guard !Task.isCancelled,
                  session.version == revision
            else {
                return
            }
            session.applyStatistics(statistics)
        }
    }

    private static func taskCheckboxStateRange(in line: String) -> Range<String.Index>? {
        let pattern = #"^\s*(?:[-*+]|\d+[.)])\s+\[([ xX])\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(line.startIndex ..< line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: fullRange) else { return nil }
        return Range(match.range(at: 1), in: line)
    }
}

private struct WorkspaceSearchActivationTarget {
    let location: WorkspaceFileSystemLocation
    let expectedIdentity: WorkspaceFileSystemIdentity
    let nodeID: WorkspaceFileNode.ID
}

@MainActor
private struct PreparedWorkspaceSearchActivation {
    let nodeID: WorkspaceFileNode.ID
    let anchoredActivation: PreparedAnchoredFileSessionActivation
    let documentIdentity: EditorDocumentIdentity
}

private extension String {
    func rangeOfOneBasedLine(_ requestedLine: Int) -> Range<String.Index>? {
        guard requestedLine > 0 else { return nil }

        var currentLine = 1
        var lineStart = startIndex

        while currentLine < requestedLine {
            guard let newline = self[lineStart...].firstIndex(where: \.isNewline) else {
                return nil
            }
            lineStart = index(after: newline)
            currentLine += 1
        }

        let lineEnd = self[lineStart...].firstIndex(where: \.isNewline) ?? endIndex
        return lineStart ..< lineEnd
    }
}
