import AppKit
import Combine
import Foundation
import MarkdownCore
import PreviewKit
import WebKit
import WorkspaceKit

/// Which File-menu export the shared snapshot is running. HTML and PDF choose a
/// destination first; Print renders first because its panel paginates that render.
enum ExportCommandProduct: Equatable {
    case html
    case pdf
    case print

    var pathExtension: String {
        switch self {
        case .html: "html"
        case .pdf, .print: "pdf"
        }
    }

    var progressNoun: String {
        switch self {
        case .html: "HTML"
        case .pdf: "PDF"
        case .print: "Print"
        }
    }

    /// HTML keeps the original sentence so existing notices stay byte-identical.
    var saveFirstVerb: String {
        switch self {
        case .html: "export it as HTML"
        case .pdf: "export it as PDF"
        case .print: "print it"
        }
    }

    var artifactNoun: String {
        switch self {
        case .html, .print: "exported HTML"
        case .pdf: "exported PDF"
        }
    }
}

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
    let product: ExportCommandProduct
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
        product: ExportCommandProduct = .html,
        window: NSWindow? = nil
    ) {
        self.operationID = operationID
        self.session = session
        textChange = session.currentTextChange
        self.stateURL = stateURL
        self.workspaceRootURL = workspaceRootURL
        self.workspaceAccess = workspaceAccess
        self.theme = theme
        self.product = product
        self.window = window
        requiresWindow = window != nil
        defaultFileName = Self.defaultFileName(for: session.fileURL, pathExtension: product.pathExtension)
        defaultDirectoryURL = session.fileURL?.deletingLastPathComponent()
    }

    /// A valid nonempty string title wins; malformed frontmatter and non-string titles fall
    /// back to the source basename. Control characters and path separators cannot enter a leaf.
    static func defaultFileName(
        for documentURL: URL?, source: String = "", pathExtension: String = "html"
    ) -> String {
        let parsed = Frontmatter.parse(source)
        let title: String? = if !parsed.isMalformed,
                                case let .string(value)? = parsed.block?.fieldValues["title"]
        {
            value
        } else {
            nil
        }
        func sanitize(_ value: String) -> String {
            let cleaned = String(value.unicodeScalars.map { scalar in
                CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":"
                    ? "-" : String(scalar)
            }.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
            var bounded = ""
            for character in cleaned.drop(while: { $0 == "." }) {
                guard bounded.utf8.count + String(character).utf8.count <= 200 else { break }
                bounded.append(character)
            }
            return bounded
        }
        let sanitizedTitle = title.map(sanitize) ?? ""
        let base = sanitizedTitle.isEmpty
            ? sanitize(documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
            : sanitizedTitle
        return "\(base.isEmpty ? "Untitled" : base).\(pathExtension)"
    }
}

/// What the save panel (or the hosted-test seam that replaces it) is asked for.
struct ExportHTMLDestinationRequest: Equatable {
    let defaultFileName: String
    let directoryURL: URL?
    var allowedExtension: String

    init(defaultFileName: String, directoryURL: URL?, allowedExtension: String = "html") {
        self.defaultFileName = defaultFileName
        self.directoryURL = directoryURL
        self.allowedExtension = allowedExtension
    }

    var accessibilityLabel: String {
        let format = allowedExtension == "pdf" ? "PDF" : "HTML"
        return "Export as \(format). Choose a destination for \(defaultFileName)."
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
    /// Print finished through AppKit. Plainsong wrote no file.
    case printed
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
    /// Installs networking configuration before the export controller constructs its web view.
    var websiteDataStoreProvider: (@MainActor () -> WKWebsiteDataStore)?
    /// Replaces only sheet presentation, after the real fresh panel has been configured.
    var savePanelPresenter: (@MainActor (NSSavePanel, NSWindow) async -> URL?)?
    /// Observes spoken announcements in hosted tests without requiring VoiceOver.
    var announcementPoster: (@MainActor (String) -> Void)?
    var panelWindowProvider: (@MainActor () -> NSWindow?)?
    /// The current operation's dedicated offscreen controller (diagnostics and tests only).
    weak var offscreenController: PreviewController?
    /// Test seam: replaces the `NSSavePanel` sheet. Return `nil` to cancel.
    var destinationChooser: (@MainActor (ExportHTMLDestinationRequest) async -> URL?)?
    /// Test seam: injects a typed writer outcome without touching a destination.
    var injectedWriteOutcome: ExportArtifactWriteOutcome?
    /// Test seam: pause after the panel-approved identity is captured, before rendering.
    var didInspectDestination: (@MainActor () async -> Void)?
    var didPrepareArtifact: (@MainActor () async -> Void)?
    /// Test seam: observes every finished operation's typed result.
    var didFinishOperation: (@MainActor (UInt64, ExportHTMLOperationResult) -> Void)?
    /// Test seam: replaces the standard print panel. Return false for cancellation.
    var printOperationRunner: (@MainActor (NSPrintOperation, NSWindow) async -> Bool)?
    weak var printHostWindow: NSWindow?
    var printCompletion: ExportPrintCompletion?
}
