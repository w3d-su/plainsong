import AppKit
import SwiftUI

/// Follows the existing in-window banner pattern; severity is conveyed by words and symbols.
struct ExportHTMLStatusBanner: View {
    @EnvironmentObject private var appState: AppState

    /// Announce each operation start once, then its result/error. Filename preparation must
    /// not repeat the progress announcement. Silent cancellation stays silent.
    @MainActor
    static func announce(
        _ status: ExportHTMLStatus?, previous: ExportHTMLStatus?,
        post: (@MainActor (String) -> Void)? = nil
    ) {
        let message: String
        switch status {
        case let .exporting(operationID, fileName):
            if case let .exporting(previousID, _) = previous, previousID == operationID { return }
            message = ExportHTMLAccessibility.progressLabel(fileName: fileName)
        case let .notice(notice):
            guard status != previous else { return }
            message = notice.accessibilityLabel
        case nil:
            return
        }
        if let post { post(message) }
        else {
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: message,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    var body: some View {
        if let status = appState.exportHTMLStatus {
            HStack(alignment: .top, spacing: 10) {
                switch status {
                case let .exporting(_, fileName):
                    ProgressView().controlSize(.small)
                    Text("Exporting \(fileName)…")
                        .accessibilityLabel(ExportHTMLAccessibility.progressLabel(fileName: fileName))
                        .accessibilityIdentifier(ExportHTMLAccessibility.progress)
                    Spacer()
                    Button("Cancel") { appState.cancelExportHTML() }
                        .accessibilityIdentifier(ExportHTMLAccessibility.cancel)
                case let .notice(notice):
                    Image(systemName: notice.severity.systemImage).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(notice.severity.spokenPrefix): \(notice.title)").bold()
                        Text(notice.message).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(notice.accessibilityLabel)
                    .accessibilityIdentifier(notice.accessibilityIdentifier)
                    Spacer()
                    if let url = notice.revealURL {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .accessibilityIdentifier(ExportHTMLAccessibility.reveal)
                    }
                    Button("Dismiss") { appState.dismissExportHTMLNotice() }
                        .accessibilityIdentifier(ExportHTMLAccessibility.dismiss)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}
