import AppKit
import Foundation
import MarkdownCore
import PreviewKit
import WorkspaceKit

/// The built-in preview theme frozen into one export (`docs/export-gates.md` D3): `system`
/// is resolved to the appearance at invocation so the file never changes theme later.
enum ExportHTMLTheme: String, Equatable {
    case light
    case dark

    static func resolve(
        _ theme: PlainsongPreferences.PreviewTheme,
        appearance: NSAppearance
    ) -> ExportHTMLTheme {
        switch theme {
        case .light:
            .light
        case .dark:
            .dark
        case .system:
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        }
    }
}

/// E1: the immutable snapshot one File › Export as HTML… operation captures at invocation.
///
/// `textChange` carries the exact source, file kind, per-document revision (`version`), and
/// the document URL from which PreviewKit derives the base directory against
/// `workspaceRootURL`, exactly as the visible preview does. The session and workspace
/// authority are held weakly so the operation never extends their lifetime; every fence
/// compares them by identity.
struct ExportHTMLOperationSnapshot {
    let operationID: UInt64
    private(set) weak var session: DocumentSession?
    let textChange: DocumentTextChange
    let stateURL: URL?
    let workspaceRootURL: URL?
    private(set) weak var workspaceAccess: SecurityScopedResourceAccess?
    let theme: ExportHTMLTheme
    let defaultFileName: String
    let defaultDirectoryURL: URL?

    @MainActor
    init(
        operationID: UInt64,
        session: DocumentSession,
        stateURL: URL?,
        workspaceRootURL: URL?,
        workspaceAccess: SecurityScopedResourceAccess?,
        theme: ExportHTMLTheme
    ) {
        self.operationID = operationID
        self.session = session
        textChange = session.currentTextChange
        self.stateURL = stateURL
        self.workspaceRootURL = workspaceRootURL
        self.workspaceAccess = workspaceAccess
        self.theme = theme
        defaultFileName = Self.defaultFileName(for: session.fileURL)
        defaultDirectoryURL = session.fileURL?.deletingLastPathComponent()
    }

    /// Phase A default: the document's base name plus `.html`, with path separators removed.
    static func defaultFileName(for documentURL: URL?) -> String {
        let baseName = documentURL?.deletingPathExtension().lastPathComponent ?? ""
        let sanitized = baseName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(sanitized.isEmpty ? "Untitled" : sanitized).html"
    }
}

/// What the save panel (or the hosted-test seam that replaces it) is asked for.
struct ExportHTMLDestinationRequest: Equatable {
    let defaultFileName: String
    let directoryURL: URL?
}

/// Why an operation ended before its bytes reached the one-shot writer. Nothing was written.
enum ExportHTMLStopReason: Error, Equatable {
    /// The panel was cancelled, or the operation task was cancelled.
    case cancelled
    /// A newer Export as HTML… operation started.
    case superseded
    /// The document was edited, switched, renamed/moved, or closed.
    case documentChanged
    /// The workspace was switched or closed.
    case workspaceChanged
    /// No file-backed Markdown/MDX document was current at invocation.
    case untitledDocument
    /// The editor still had input waiting to synchronize into the document.
    case pendingEditorSource
    /// The offscreen render or the D2 export barrier failed (for example `mdx-stale-or-error`).
    case renderFailed(reason: String)
    /// `ExportArtifactWriter.inspectDestination` refused the panel URL before any write.
    case destinationRefused(ExportArtifactFailure)
}

enum ExportHTMLOperationResult: Equatable {
    case stopped(ExportHTMLStopReason)
    /// The writer ran; its typed committed / not-committed / indeterminate outcome.
    case written(ExportArtifactWriteOutcome)
}

/// App-owned bookkeeping for Export as HTML…: the monotonic operation counter, the one
/// active operation, and the seams hosted tests use instead of a real save panel.
struct ExportHTMLOperationRegistry {
    var lastOperationID: UInt64 = 0
    var activeOperationID: UInt64?
    var activeTask: Task<Void, Never>?
    weak var presentedPanel: NSSavePanel?
    /// The current operation's dedicated offscreen controller (diagnostics and tests only).
    weak var offscreenController: PreviewController?
    /// Test seam: replaces the `NSSavePanel` sheet. Return `nil` to cancel.
    var destinationChooser: (@MainActor (ExportHTMLDestinationRequest) async -> URL?)?
    /// Test seam: observes every finished operation's typed result.
    var didFinishOperation: (@MainActor (UInt64, ExportHTMLOperationResult) -> Void)?
}

/// Phase A result text. Deliberately literal: it names the exact `ExportArtifactFailure`
/// and every exact path an indeterminate write reports, so the owner smoke can record them.
enum ExportHTMLResultMessage {
    static func notice(for result: ExportHTMLOperationResult) -> (title: String, message: String)? {
        switch result {
        case .stopped(.cancelled), .stopped(.superseded):
            nil
        case let .stopped(reason):
            ("Could Not Export as HTML", "\(stopDescription(reason)) Nothing was written.")
        case let .written(.committed(commit)):
            ("Exported as HTML", "Wrote \(commit.selectedURL.path(percentEncoded: false)).")
        case let .written(.notCommitted(failure)):
            ("Could Not Export as HTML", "Nothing was written. Reason: \(failureDescription(failure)).")
        case let .written(.indeterminate(write)):
            ("HTML Export Could Not Be Confirmed", indeterminateDescription(write))
        }
    }

    static func failureDescription(_ failure: ExportArtifactFailure) -> String {
        "ExportArtifactFailure.\(failure)"
    }

    private static func stopDescription(_ reason: ExportHTMLStopReason) -> String {
        switch reason {
        case .cancelled, .superseded:
            "The export was cancelled."
        case .documentChanged:
            "The document changed while it was being exported."
        case .workspaceChanged:
            "The workspace changed while the document was being exported."
        case .untitledDocument:
            "Save the document before exporting it as HTML."
        case .pendingEditorSource:
            "The editor still has input waiting to synchronize. Try again."
        case let .renderFailed(reason):
            "The document could not be rendered for export (\(reason))."
        case let .destinationRefused(failure):
            "The destination was refused: \(failureDescription(failure))."
        }
    }

    private static func indeterminateDescription(_ write: ExportArtifactIndeterminateWrite) -> String {
        func path(_ url: URL) -> String {
            url.path(percentEncoded: false)
        }
        var lines = [
            "The export to \(path(write.selectedURL)) could not be confirmed " +
                "(WorkspaceAnchoredFileSystemError.\(write.reason)).",
        ]
        switch write.destinationState {
        case .holdsWriterBytes:
            lines.append("The selected file holds the exported HTML, but cleanup was not proven.")
        case .provenUnchanged:
            lines.append("The selected file was proven unchanged.")
        case .unknown:
            lines.append("The selected file's state could not be proven.")
        }
        switch write.residue {
        case .none:
            break
        case let .retained(url, .displacedOriginal):
            lines.append("Your original file is now at \(path(url)).")
        case let .retained(url, .writerBytes):
            lines.append("The exported bytes remain at \(path(url)).")
        case let .retained(url, .unknown):
            lines.append("An unexpected entry remains at \(path(url)); inspect it before reuse.")
        case let .removalIndeterminate(url):
            lines.append("Removal of \(path(url)) could not be confirmed; inspect it before reuse.")
        }
        if let stagingURL = write.stagingURL {
            lines.append("Operation entry to inspect: \(path(stagingURL)).")
        }
        return lines.joined(separator: " ")
    }
}
