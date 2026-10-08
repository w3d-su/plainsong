import EditorKitIOS
import Foundation
import MarkdownCore

extension IOSAuthoringController {
    func setFindQuery(_ text: String, using editor: any IOSSourceEditorControlling) {
        find.queryText = text
        beginFindQuery(using: editor)
    }

    func setFindCase(_ sensitivity: TextSearchCaseSensitivity, using editor: any IOSSourceEditorControlling) {
        guard find.caseSensitivity != sensitivity else { return }
        find.caseSensitivity = sensitivity
        beginFindQuery(using: editor)
    }

    func setFindWholeWord(_ wholeWord: Bool, using editor: any IOSSourceEditorControlling) {
        guard find.wholeWord != wholeWord else { return }
        find.wholeWord = wholeWord
        beginFindQuery(using: editor)
    }

    func setReplacement(_ replacement: String) {
        find.replacement = replacement
    }

    func noteFindFieldFocused(using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        find.editorSelection = snapshot.selection
        find.hasEditorSelection = true
    }

    func beginFindQuery(using editor: any IOSSourceEditorControlling) {
        find.queryGeneration &+= 1
        find.pendingSteps = 0
        find.session = nil
        guard let snapshot = editor.captureSnapshot() else { return }
        find.editorSelection = snapshot.selection
        find.hasEditorSelection = true
        switch IOSFindQuery.classify(find.queryText) {
        case .empty:
            find.status = .empty
            find.counterText = ""
            find.message = ""
        case .invalid:
            find.status = .invalid
            find.counterText = ""
            find.message = IOSFindQuery.invalidMessage
        case .searchable:
            let generation = find.queryGeneration
            let revision = snapshot.revision
            let bindingID = snapshot.bindingID
            let text = snapshot.document.text
            let query = makeQuery()
            let caret = max(0, snapshot.selection.location)
            find.status = .searching
            find.message = ""
            findScheduler.schedule(operation: {
                EditorFindSession.search(in: text, query: query, caretAnchorUTF16: caret)
            }, deliver: { [weak self] session in
                self?.receiveFind(
                    session,
                    generation: generation,
                    revision: revision,
                    bindingID: bindingID,
                    using: editor
                )
            })
        }
    }

    func stepFind(by steps: Int, using editor: any IOSSourceEditorControlling) {
        guard steps != 0, let snapshot = editor.captureSnapshot(), !snapshot.hasMarkedText else { return }
        if find.status == .searching {
            find.pendingSteps += steps
            return
        }
        guard var session = find.session, !session.matches.isEmpty else { return }
        session = steps > 0 ? session.next() : session.previous()
        if abs(steps) > 1 {
            let extra = steps > 0 ? steps - 1 : steps + 1
            session = session.stepped(by: extra)
        }
        find.session = session
        publishFind(session)
        revealFindMatch(in: session, snapshot: snapshot, using: editor)
    }

    func useSelectionForFind(using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        find.editorSelection = snapshot.selection
        find.hasEditorSelection = true
        let storage = snapshot.document.text as NSString
        let selection = snapshot.selection
        guard let end = checkedEnd(selection), end <= storage.length, selection.length > 0 else { return }
        let selected = storage.substring(with: selection)
        guard IOSFindQuery.classify(selected) == .searchable else { return }
        find.queryText = selected
        beginFindQuery(using: editor)
    }

    func replaceCurrentMatch(using editor: any IOSSourceEditorControlling) {
        guard let snapshot = editor.captureSnapshot() else { return }
        if snapshot.hasMarkedText {
            statusMessage = IOSAuthoringCatalog.compositionRefusal
            return
        }
        guard find.status != .searching,
              let session = find.session,
              session.query == makeQuery(),
              let match = session.currentMatch
        else {
            return
        }
        if snapshot.selection != match.range {
            _ = editor.reveal(match.range, expected: snapshot.revision)
            return
        }
        switch EditorReplacePlanner.planOneMatch(
            session: session,
            source: snapshot.document.text,
            replacement: find.replacement
        ) {
        case let .failure(refusal):
            statusMessage = replacementMessage(refusal)
        case let .success(plan) where plan.isLiteralIdentical:
            let continuation = EditorReplaceContinuationPlanning.afterLiteralIdentical(
                plan: plan,
                session: session
            )
            install(continuation, snapshot: snapshot, using: editor)
        case let .success(plan):
            let result = MarkdownEditResult(
                replacementRange: plan.match.range,
                replacementString: plan.replacement,
                newSelection: NSRange(location: plan.resumeUTF16, length: 0)
            )
            let outcome = submit(result, snapshot: snapshot, name: "Replace", using: editor)
            guard case let .applied(revision) = outcome,
                  let latest = editor.captureSnapshot(),
                  latest.revision == revision,
                  let planned = EditorReplaceSourceConstruction.replacedSource(
                      snapshot.document.text,
                      ranges: [plan.match.range],
                      replacement: plan.replacement
                  ),
                  ExactSourceText.matches(latest.document.text, planned)
            else {
                return
            }
            let continuation = EditorReplaceContinuationPlanning.afterOneReplace(
                plan: plan,
                postWriteSource: latest.document.text
            )
            install(continuation, snapshot: latest, using: editor)
        }
    }

    func receiveFind(
        _ session: EditorFindSession,
        generation: UInt64,
        revision: IOSDocumentRevision,
        bindingID: UUID,
        using editor: any IOSSourceEditorControlling
    ) {
        guard generation == find.queryGeneration else { return }
        guard let live = editor.captureSnapshot(),
              live.bindingID == bindingID,
              live.revision == revision
        else {
            find.pendingSteps = 0
            if find.status == .searching {
                find.status = .empty
                find.counterText = ""
                find.message = ""
            }
            return
        }
        var resolved = session
        let steps = find.pendingSteps
        if steps != 0 {
            resolved = resolved.stepped(by: steps)
            find.pendingSteps = 0
        }
        find.session = resolved
        publishFind(resolved)
        if steps != 0 {
            revealFindMatch(in: resolved, snapshot: live, using: editor)
        }
    }

    private func install(
        _ continuation: EditorReplaceContinuation,
        snapshot: IOSSourceEditorSnapshot,
        using editor: any IOSSourceEditorControlling
    ) {
        find.session = continuation.session
        publishFind(continuation.session)
        if continuation.session.currentOrdinal != nil {
            revealFindMatch(in: continuation.session, snapshot: snapshot, using: editor)
        }
    }

    private func publishFind(_ session: EditorFindSession) {
        if session.total == 0 {
            find.status = .noResults
            find.counterText = ""
            find.message = IOSFindQuery.noResultsMessage
            return
        }
        find.status = .matches
        find.counterText = IOSFindQuery.counter(for: session)
        find.message = ""
    }

    private func revealFindMatch(
        in session: EditorFindSession,
        snapshot: IOSSourceEditorSnapshot,
        using editor: any IOSSourceEditorControlling
    ) {
        guard !snapshot.hasMarkedText, let match = session.currentMatch else { return }
        _ = editor.reveal(match.range, expected: snapshot.revision)
    }

    private func makeQuery() -> TextSearchQuery {
        TextSearchQuery(
            pattern: find.queryText,
            caseSensitivity: find.caseSensitivity,
            wholeWord: find.wholeWord
        )
    }

    private func replacementMessage(_ refusal: EditorReplacePlanRefusal) -> String {
        switch refusal {
        case .invalidReplacement(.containsNewline):
            "Replacement can't contain a line break."
        case .invalidReplacement(.exceedsMaximumUTF16Length):
            "Replacement can't be longer than 256 characters."
        case .invalidReplacement(.valid):
            "Replacement isn't valid."
        case .emptySession, .noCurrentMatch:
            "There is no current match to replace."
        case .truncatedSession, .projectedLengthOverflow:
            IOSAuthoringCatalog.formattingRefusal
        }
    }

    private func checkedEnd(_ range: NSRange) -> Int? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        return overflow ? nil : end
    }
}
