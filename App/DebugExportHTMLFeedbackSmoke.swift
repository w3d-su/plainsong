#if DEBUG
    import Foundation
    import WorkspaceKit

    @MainActor
    extension AppState {
        /// Owner-only wording preview. It never writes, moves, or removes a file. Set the launch
        /// environment to `displaced-original` or `unknown`; Release builds contain no entry point.
        func showExportHTMLFeedbackSmokeIfRequested(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            guard let mode = environment["PLAINSONG_EXPORT_FEEDBACK_SMOKE"],
                  mode == "displaced-original" || mode == "unknown"
            else { return }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-feedback-preview")
            let directory = root.appendingPathComponent(".TemporaryItems/replacement")
            let original = directory.appendingPathComponent("original.html")
            let result = ExportHTMLOperationResult.written(.indeterminate(ExportArtifactIndeterminateWrite(
                reason: .cleanupFailed,
                selectedURL: root.appendingPathComponent("output.html"),
                destinationState: mode == "displaced-original" ? .holdsWriterBytes : .unknown,
                residue: .retained(original, holding: mode == "displaced-original" ? .displacedOriginal : .unknown),
                stagingURL: directory.appendingPathComponent("stage.html"),
                itemReplacementDirectoryURL: directory,
                unprovenDirectoryURLs: [root.appendingPathComponent(".TemporaryItems")],
                residueIsInPurgeableTemporaryFolder: true
            )))
            guard let notice = ExportHTMLNoticeMapper.notice(for: result, operationID: 0) else { return }
            exportHTMLStatus = .notice(ExportHTMLNotice(
                operationID: notice.operationID, group: notice.group, severity: notice.severity,
                title: "Preview Only — \(notice.title)",
                message: "Test preview: no files were written or moved. " + notice.message,
                revealURL: nil
            ))
        }
    }
#endif
