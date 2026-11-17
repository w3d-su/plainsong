import Foundation
import MarkdownCore

extension IOSSourceEditorController {
    func cancelStatisticsRefresh() {
        statisticsTask?.cancel()
        statisticsTask = nil
    }

    func scheduleStatisticsRefresh(for binding: IOSSourceEditorDocumentBinding) {
        cancelStatisticsRefresh()
        let revision = currentRevision(binding)
        let bindingID = binding.bindingID
        let text = binding.session.text
        statisticsTask = Task.detached(priority: .utility) { [weak self, statisticsDebounce, countStatistics] in
            do {
                try await statisticsDebounce()
            } catch {
                return
            }
            guard !Task.isCancelled, let statistics = await countStatistics(text) else { return }
            await self?.publishStatistics(statistics, for: revision, bindingID: bindingID)
        }
    }

    private func publishStatistics(_ statistics: TextStatistics, for revision: IOSDocumentRevision, bindingID: UUID) {
        guard !Task.isCancelled, isHostAlive, let installation,
              installation.bindingID == bindingID, installation.identity == revision.documentID else { return }
        statisticsTask = nil
        let session = installation.session
        guard session.version == revision.version else {
            // A URL or file-kind change can advance the revision without supplying fresh counts.
            if session.needsStatisticsRefresh {
                scheduleStatisticsRefresh(for: installation)
            }
            return
        }
        let changed = session.availableStatistics != statistics
        session.applyStatistics(statistics)
        if changed { emitSnapshot() }
    }
}
