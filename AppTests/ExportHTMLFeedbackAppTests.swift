import AppKit
import Darwin
import MarkdownCore
@testable import Plainsong
@testable import WorkspaceKit
import XCTest

@MainActor
final class ExportHTMLFeedbackAppTests: XCTestCase {
    func testEveryWriterFailureMapsToAnActionableAccessibleGroup() throws {
        for (failure, group) in Self.failures {
            let appState = AppState(shouldRestoreLastOpenedFile: false)
            appState.presentExportHTMLResult(.written(.notCommitted(failure)), operationID: 42)
            let notice = try XCTUnwrap(appState.exportHTMLNotice)
            XCTAssertEqual(notice.operationID, 42)
            XCTAssertEqual(notice.group, group, "\(failure)")
            XCTAssertEqual(notice.severity, .failure)
            XCTAssertTrue(notice.message.hasPrefix("Nothing was written."))
            XCTAssertTrue(notice.accessibilityLabel.contains(notice.message))
            XCTAssertTrue(notice.accessibilityLabel.hasPrefix("Error:"))
            XCTAssertEqual(notice.accessibilityIdentifier, "export-html-notice-\(group.rawValue)")
            XCTAssertFalse(notice.message.contains("ExportArtifactFailure"))
        }
    }

    func testIndeterminateStatesAndEveryResidueReportRecoveryPathsWithoutClaimingSuccess() throws {
        let selected = URL(fileURLWithPath: "/Smoke/output.html")
        let directory = URL(fileURLWithPath: "/Smoke/.TemporaryItems/replacement")
        let residue = directory.appendingPathComponent("original")
        let scaffolding = URL(fileURLWithPath: "/Smoke/.TemporaryItems")
        let residues: [ExportArtifactResidue] = [
            .none, .retained(residue, holding: .displacedOriginal),
            .retained(residue, holding: .writerBytes), .retained(residue, holding: .unknown),
            .removalIndeterminate(residue),
        ]
        for state in [ExportArtifactDestinationState.holdsWriterBytes, .provenUnchanged, .unknown] {
            for remaining in residues {
                let write = ExportArtifactIndeterminateWrite(
                    reason: .cleanupFailed, selectedURL: selected, destinationState: state,
                    residue: remaining, stagingURL: directory.appendingPathComponent("stage"),
                    itemReplacementDirectoryURL: directory, unprovenDirectoryURLs: [scaffolding],
                    residueIsInPurgeableTemporaryFolder: true
                )
                let notice = try XCTUnwrap(ExportHTMLNoticeMapper.notice(
                    for: .written(.indeterminate(write)),
                    operationID: 1
                ))
                XCTAssertEqual(notice.group, .indeterminate)
                XCTAssertEqual(notice.severity, .failure)
                for path in [
                    selected.path,
                    directory.path,
                    scaffolding.path,
                    directory.appendingPathComponent("stage").path,
                ] {
                    XCTAssertTrue(notice.message.contains(path))
                    XCTAssertTrue(notice.accessibilityLabel.contains(path))
                }
                if case .retained(_, .displacedOriginal) = remaining {
                    XCTAssertTrue(notice.message.contains("Your original file is now at \(residue.path)"))
                    XCTAssertTrue(notice.message.contains("macOS may clear"))
                    XCTAssertTrue(notice.message.contains("recover the file now"))
                    XCTAssertEqual(notice.revealURL, residue)
                }
                if case .retained(_, .unknown) = remaining { XCTAssertTrue(notice.message.contains("may be your data"))
                }
                if case .removalIndeterminate = remaining { XCTAssertTrue(notice.message.contains("may be your data")) }
            }
        }
    }

    func testCancelSupersessionAndCancelledWriterAreSilent() {
        for result in [ExportHTMLOperationResult.stopped(.cancelled), .stopped(.superseded),
                       .written(.notCommitted(.cancelled)), .stopped(.destinationRefused(.cancelled))]
        {
            XCTAssertNil(ExportHTMLNoticeMapper.notice(for: result, operationID: 1))
        }
    }

    func testStopReasonsHaveDistinctAccessibleMessagesAndStableControls() throws {
        let cases: [(ExportHTMLStopReason, ExportHTMLNoticeGroup)] = [
            (.untitledDocument, .saveDocumentFirst), (.unprovenDocumentOwnership, .saveDocumentFirst),
            (.recoveryStoresUnavailable, .recoveryUnavailable), (.documentChanged, .documentChanged),
            (.workspaceChanged, .workspaceChanged), (.pendingEditorSource, .editorBusy),
            (.renderFailed(reason: "timeout"), .renderFailed),
            (.renderFailed(reason: "resources-changed"), .resourceFailed),
            (.renderFailed(reason: "html-too-large"), .resourceFailed), (
                .renderFailed(reason: "mdx-stale-or-error"),
                .mdxError
            ),
        ]
        for (reason, group) in cases {
            let notice = try XCTUnwrap(ExportHTMLNoticeMapper.notice(for: .stopped(reason), operationID: 1))
            XCTAssertEqual(notice.group, group)
            XCTAssertTrue(notice.message.contains("Nothing was written."))
            XCTAssertTrue(notice.accessibilityLabel.contains(notice.title))
        }
        XCTAssertEqual(Set([ExportHTMLAccessibility.command, ExportHTMLAccessibility.savePanel,
                            ExportHTMLAccessibility.progress, ExportHTMLAccessibility.cancel,
                            ExportHTMLAccessibility.reveal, ExportHTMLAccessibility.dismiss]).count, 6)
        XCTAssertEqual(ExportHTMLAccessibility.progressLabel(fileName: "post.html"),
                       "Exporting post.html as HTML. Cancel to stop the export.")
    }

    #if DEBUG
        func testOwnerFeedbackPreviewDoesNotCreateOrMoveAnyFile() throws {
            for mode in ["displaced-original", "unknown"] {
                let appState = AppState(shouldRestoreLastOpenedFile: false)
                appState.showExportHTMLFeedbackSmokeIfRequested(environment: ["PLAINSONG_EXPORT_FEEDBACK_SMOKE": mode])
                let notice = try XCTUnwrap(appState.exportHTMLNotice)
                XCTAssertEqual(notice.group, .indeterminate)
                XCTAssertTrue(notice.title.hasPrefix("Preview Only"))
                XCTAssertTrue(notice.message.contains("no files were written or moved"))
                XCTAssertNil(notice.revealURL)
                XCTAssertNil(appState.exportHTMLOperations.activeOperationID)
            }
        }
    #endif

    static let failures: [(ExportArtifactFailure, ExportHTMLNoticeGroup)] = [
        (.destinationAlias, .destinationAlias), (.destinationUnreadable(code: EACCES), .destinationUnreadable),
        (.destinationAlreadyExists, .destinationChanged), (.destinationIdentityChanged, .destinationChanged),
        (.destinationMissing, .destinationChanged), (.namespaceChanged, .destinationChanged),
        (.ownedDestination, .ownedDestination), (.symbolicLinkDestination, .linkOrNonRegularDestination),
        (.symbolicLinkInParentPath, .linkOrNonRegularDestination), (
            .nonRegularDestination,
            .linkOrNonRegularDestination
        ),
        (.unsupportedVolumeSemantics, .unsupportedLocation), (.stagingDirectoryOnDifferentDevice, .unsupportedLocation),
        (.stagingDirectoryUnavailable, .unsupportedLocation), (
            .stagingDirectoryInsideDestinationFolder,
            .unsupportedLocation
        ),
        (.stagingNotPermitted(code: EPERM), .permissionMissing), (
            .publicationNotPermitted(code: EPERM),
            .permissionMissing
        ),
        (.parentAuthorityUnavailable, .permissionMissing), (.coordinationFailed, .coordinationFailed),
        (.invalidDestinationURL, .invalidName), (.unsupportedExtension, .invalidName),
        (.stagingUnavailable(code: ENOSPC), .writeFailed), (.writeFailed(.durabilityFailed), .writeFailed),
    ]
}
