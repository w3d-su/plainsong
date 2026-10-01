import AppKit
import Combine
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
    private(set) weak var window: NSWindow?
    let requiresWindow: Bool
    let defaultFileName: String
    let defaultDirectoryURL: URL?

    @MainActor
    init(
        operationID: UInt64,
        session: DocumentSession,
        stateURL: URL?,
        workspaceRootURL: URL?,
        workspaceAccess: SecurityScopedResourceAccess?,
        theme: ExportHTMLTheme,
        window: NSWindow? = nil
    ) {
        self.operationID = operationID
        self.session = session
        textChange = session.currentTextChange
        self.stateURL = stateURL
        self.workspaceRootURL = workspaceRootURL
        self.workspaceAccess = workspaceAccess
        self.theme = theme
        self.window = window
        requiresWindow = window != nil
        defaultFileName = Self.defaultFileName(for: session.fileURL)
        defaultDirectoryURL = session.fileURL?.deletingLastPathComponent()
    }

    /// A valid nonempty string title wins; malformed frontmatter and non-string titles fall
    /// back to the source basename. Control characters and path separators cannot enter a leaf.
    static func defaultFileName(for documentURL: URL?, source: String = "") -> String {
        let parsed = Frontmatter.parse(source)
        let title: String? = if !parsed.isMalformed,
                                case let .string(value)? = parsed.block?.fieldValues["title"]
        {
            value
        } else {
            nil
        }
        func sanitize(_ value: String) -> String {
            String(value.unicodeScalars.map { scalar in
                CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":"
                    ? "-" : String(scalar)
            }.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sanitizedTitle = title.map(sanitize) ?? ""
        let base = sanitizedTitle.isEmpty
            ? sanitize(documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
            : sanitizedTitle
        return "\(base.isEmpty ? "Untitled" : base).html"
    }
}

/// What the save panel (or the hosted-test seam that replaces it) is asked for.
struct ExportHTMLDestinationRequest: Equatable {
    let defaultFileName: String
    let directoryURL: URL?
    var allowedExtension: String {
        "html"
    }

    var accessibilityLabel: String {
        "Export as HTML. Choose a destination for \(defaultFileName)."
    }
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
    case unprovenDocumentOwnership
    case recoveryStoresUnavailable
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
    case exported(ExportArtifactCommit, omittedImageCount: Int)
}

/// App-owned bookkeeping for Export as HTML…: the monotonic operation counter, the one
/// active operation, and the seams hosted tests use instead of a real save panel.
struct ExportHTMLOperationRegistry {
    var lastOperationID: UInt64 = 0
    var activeOperationID: UInt64?
    var contextStopReason: ExportHTMLStopReason?
    var activeTask: Task<Void, Never>?
    weak var presentedPanel: NSSavePanel?
    var panelOperationID: UInt64?
    var windowCloseObserver: AnyCancellable?
    var panelWindowProvider: (@MainActor () -> NSWindow?)?
    /// The current operation's dedicated offscreen controller (diagnostics and tests only).
    weak var offscreenController: PreviewController?
    /// Test seam: replaces the `NSSavePanel` sheet. Return `nil` to cancel.
    var destinationChooser: (@MainActor (ExportHTMLDestinationRequest) async -> URL?)?
    /// Test seam: observes every finished operation's typed result.
    /// Test seam: injects a typed writer outcome without touching a destination.
    var injectedWriteOutcome: ExportArtifactWriteOutcome?
    /// Test seam: pause after the panel-approved identity is captured, before rendering.
    var didInspectDestination: (@MainActor () async -> Void)?
    var didPrepareArtifact: (@MainActor () async -> Void)?
    var didFinishOperation: (@MainActor (UInt64, ExportHTMLOperationResult) -> Void)?
}
