import MarkdownCore

extension IOSSourceEditorController {
    /// The session owns the count and its 300 ms pause, as on macOS: a newer edit cancels it,
    /// and it keeps running for its document when the editor detaches or closes. While text
    /// is marked (a Zhuyin composition), counting waits until the composition ends.
    func scheduleStatisticsRefresh(for session: DocumentSession) {
        if textView.markedTextRange != nil {
            hasUncountedComposition = true
        } else {
            countStatistics(of: session)
        }
    }

    /// Counts the source a composition left uncounted, once it is committed or cancelled,
    /// or when its document leaves this editor first.
    func countStatisticsAfterComposition() {
        guard hasUncountedComposition, let session = installation?.session else { return }
        countStatistics(of: session)
    }

    private func countStatistics(of session: DocumentSession) {
        hasUncountedComposition = false
        session.scheduleStatisticsRefreshAfterEdit { [weak self] counted in
            // Chrome reads the editor snapshot, which was emitted before this count finished.
            guard let self, installation?.session === counted else { return }
            emitSnapshot()
        }
    }
}
