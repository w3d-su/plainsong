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
              newText != session.text
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
