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
              !ExactSourceText.matches(newText, session.text)
        else {
            return
        }

        session.replaceText(newText, refreshStatistics: false)
        if let url = session.fileURL?.standardizedFileURL {
            sessionPolicy.updateDirtyState(for: url, isDirty: session.isDirty)
        }
        scheduleStatisticsRefresh()
        scheduleCompletionWorkspaceRefresh(debounceNanoseconds: 250_000_000)
        scheduleAutosave()
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
        currentDocument.fileURL.map(Self.editorDocumentIdentity(for:))
    }

    func activateWorkspaceSearchResult(
        context: WorkspaceSearchContext,
        fileResult: WorkspaceSearchFileResult,
        match: TextSearchMatch
    ) {
        guard let target = workspaceSearchActivationTarget(
            context: context,
            fileResult: fileResult,
            match: match
        ), var tree = workspaceTree
        else {
            return
        }

        let previousTree = tree
        tree.selectNode(id: target.nodeID)
        workspaceTree = tree

        do {
            try activateFileSession(url: target.fileURL)
        } catch {
            workspaceTree = previousTree
            present(error, title: "Could Not Open Search Result")
            return
        }

        guard let activatedURL = currentDocument.fileURL?.standardizedFileURL,
              !detachedSessionURLs.contains(activatedURL)
        else {
            workspaceTree = previousTree
            return
        }
        let activatedIdentity = Self.editorDocumentIdentity(for: activatedURL)
        let expectedIdentity = Self.editorDocumentIdentity(for: target.fileURL)
        guard ExactSourceText.matches(activatedIdentity.rawValue, expectedIdentity.rawValue) else {
            workspaceTree = previousTree
            return
        }

        let activeFingerprint = WorkspaceSearchContentFingerprint(text: currentDocument.text)
        guard activeFingerprint.sha256Digest == fileResult.contentFingerprint.sha256Digest,
              activeFingerprint.utf8ByteCount == fileResult.contentFingerprint.utf8ByteCount
        else {
            cancelPendingEditorNavigationIfNeeded(force: true)
            restartActiveWorkspaceSearchWithFreshOverlays()
            return
        }

        guard Self.isValidEditorRange(
            match.range,
            textUTF16Length: currentDocument.text.utf16.count
        ) else {
            return
        }

        issueEditorNavigation(
            documentIdentity: activatedIdentity,
            selection: match.range
        )
    }

    private func workspaceSearchActivationTarget(
        context: WorkspaceSearchContext,
        fileResult: WorkspaceSearchFileResult,
        match: TextSearchMatch
    ) -> WorkspaceSearchActivationTarget? {
        guard isActiveWorkspaceSearchContext(context),
              let storedResult = workspaceSearchState.fileResults.first(where: {
                  ExactSourceText.matches($0.relativePath, fileResult.relativePath)
              }),
              storedResult == fileResult,
              storedResult.matches.contains(match),
              Self.isStructurallyValidEditorRange(match.range),
              let rootURL = workspaceRootURL?.standardizedFileURL,
              let tree = workspaceTree,
              let node = firstNode(in: tree.root, relativePath: fileResult.relativePath),
              node.isEditableMarkdown,
              let fileURL = try? WorkspaceRootContainment.containedURL(
                  rootURL: rootURL,
                  relativePath: fileResult.relativePath
              )
        else {
            return nil
        }

        return WorkspaceSearchActivationTarget(fileURL: fileURL, nodeID: node.id)
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

    static func editorDocumentIdentity(for url: URL) -> EditorDocumentIdentity {
        EditorDocumentIdentity(
            rawValue: url.standardizedFileURL.resolvingSymlinksInPath().absoluteString
        )
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

    private func scheduleStatisticsRefresh() {
        statisticsTask?.cancel()
        statisticsTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }

            // Counting a large document is O(n); keep it off the main thread.
            let text = currentDocument.text
            let statistics = await Task.detached(priority: .utility) {
                TextStatistics(text: text)
            }.value

            guard !Task.isCancelled else { return }
            currentDocument.applyStatistics(statistics)
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
    let fileURL: URL
    let nodeID: WorkspaceFileNode.ID
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
