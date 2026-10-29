import Foundation
import MarkdownCore
import PreviewKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

enum IOSDocumentExportKind: String, Identifiable {
    case html
    case pdf
    case print

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .html: "Export as HTML"
        case .pdf: "Export as PDF"
        case .print: "Print"
        }
    }

    var pathExtension: String {
        switch self {
        case .html: "html"
        case .pdf, .print: "pdf"
        }
    }

    var contentType: UTType {
        switch self {
        case .html: .html
        case .pdf, .print: .pdf
        }
    }
}

enum IOSExportFileName {
    /// Same title rules as the Mac export panel: frontmatter title, then the file
    /// name, with control characters and path separators removed.
    static func make(source: String, fileURL: URL?, pathExtension: String) -> String {
        let parsed = Frontmatter.parse(source)
        let title: String? = if !parsed.isMalformed,
                                case let .string(value)? = parsed.block?.fieldValues["title"]
        {
            value
        } else {
            nil
        }
        let sanitizedTitle = title.map(sanitize) ?? ""
        let base = sanitizedTitle.isEmpty
            ? sanitize(fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
            : sanitizedTitle
        return "\(base.isEmpty ? "Untitled" : base).\(pathExtension)"
    }

    private static func sanitize(_ value: String) -> String {
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
}

struct IOSExportedFileDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.html, .pdf]
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration _: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnknown)
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The preview theme frozen into one export (Mac `ExportHTMLTheme`): Print is always
/// light, because paper is white and backgrounds are not printed. HTML and PDF resolve
/// `system` to the appearance at invocation, so the file never changes theme later.
enum IOSExportTheme {
    static func resolve(kind: IOSDocumentExportKind, preference: String, systemIsDark: Bool) -> String {
        if kind == .print {
            return "light"
        }
        switch preference {
        case "light", "dark":
            return preference
        default:
            return systemIsDark ? "dark" : "light"
        }
    }
}

/// The paper aspect a printed PDF is planned for (Mac: `exportPrintPageAspect`). iOS asks
/// for paper only once the print panel is up, so the plan uses the locale's default sheet:
/// US Letter where the locale measures in US units, A4 otherwise. The printable area is a
/// fixed half-inch margin. `UIPrintPaper.bestPaper` is not given an empty paper list; that
/// result is undocumented. Choosing another sheet in the panel scales this PDF. It does
/// not plan the pages again.
enum IOSPrintPage {
    static let letter = CGSize(width: 612, height: 792)
    static let a4 = CGSize(width: 595.2, height: 841.8)
    /// Half an inch, in PDF points.
    static let margin: CGFloat = 36

    static func defaultPaperSize(locale: Locale = .current) -> CGSize {
        locale.measurementSystem == .us ? letter : a4
    }

    static func defaultImageableRect(locale: Locale = .current) -> CGRect {
        let size = defaultPaperSize(locale: locale)
        return CGRect(
            x: margin,
            y: margin,
            width: size.width - (margin * 2),
            height: size.height - (margin * 2)
        )
    }

    static func imageableAspect(printableRect: CGRect) -> CGFloat? {
        guard printableRect.width > 0, printableRect.height > 0 else { return nil }
        return printableRect.height / printableRect.width
    }

    static func defaultImageableAspect(locale: Locale = .current) -> CGFloat {
        let rect = defaultImageableRect(locale: locale)
        return rect.height / rect.width
    }
}

/// One user export. HTML and PDF share the Mac offscreen preview: a dedicated export
/// controller whose content rule blocks every HTTP(S) load, a non-persistent data store,
/// remote images forced off, then the existing render barrier. Local images load through
/// the scene's grant reader. PDF continues into the same page planner and WebKit capture.
@MainActor
final class IOSDocumentExportController: ObservableObject {
    @Published var isPresented = false
    @Published var file: IOSExportedFileDocument?
    @Published var contentType: UTType = .html
    @Published var filename = "Untitled.html"
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?

    private var task: Task<Void, Never>?
    private(set) var completionNote: String?
    var onNote: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Test seam: replaces the system print panel.
    var presentPrintOverride: ((Data, String, String) -> Void)?
    /// Test seam: observes the paper aspect a printed PDF was planned for.
    var onPrintAspect: ((CGFloat) -> Void)?
    /// Test seam: suspends a run before it builds the preview.
    var onPrepareForTesting: (@MainActor () async -> Void)?
    private var runID: UInt64 = 0

    /// Stops a running export and lets another begin immediately. The stopped run's
    /// cleanup cannot clear the newer one.
    func cancel() {
        task?.cancel()
        task = nil
        runID &+= 1
        isRunning = false
        status = nil
    }

    func begin(
        _ kind: IOSDocumentExportKind,
        source: DocumentTextChange,
        assetAccess: PreviewAssetAccessContext?,
        theme: String,
        assetReader: (any PreviewAssetReading)?,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        guard !isRunning else { return }
        runID &+= 1
        let id = runID
        isRunning = true
        status = kind == .html ? "Preparing HTML…" : "Preparing PDF…"
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(
                id,
                kind,
                source: source,
                assetAccess: assetAccess,
                theme: theme,
                assetReader: assetReader,
                isCurrent: isCurrent
            )
        }
    }

    func finishPresentation(_ result: Result<URL, Error>) {
        defer { completionNote = nil }
        switch result {
        case .success:
            if let completionNote, !completionNote.isEmpty {
                onNote?(completionNote)
            }
        case let .failure(error):
            if (error as? CocoaError)?.code == .userCancelled {
                return
            }
            onFailure?(error.localizedDescription)
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func run(
        _ runID: UInt64,
        _ kind: IOSDocumentExportKind,
        source: DocumentTextChange,
        assetAccess: PreviewAssetAccessContext?,
        theme: String,
        assetReader: (any PreviewAssetReading)?,
        isCurrent: @MainActor () -> Bool
    ) async {
        defer {
            if self.runID == runID {
                isRunning = false
                status = nil
            }
        }
        func stopped() -> Bool {
            self.runID != runID || Task.isCancelled || !isCurrent()
        }
        if let onPrepareForTesting {
            await onPrepareForTesting()
            if stopped() { return }
        }
        let preview: PreviewController
        do {
            preview = try await PreviewController.makeHTMLExportController()
        } catch {
            if !stopped() {
                onFailure?("The export could not be prepared. Try again.")
            }
            return
        }
        let host = IOSExportPreviewHost(webView: preview.webView)
        defer {
            preview.invalidate()
            host.remove()
        }
        if let assetReader {
            preview.installAssetReader(assetReader)
        }
        // D1: export never follows the live preview's remote-image preference.
        preview.setAllowsRemoteImages(false)
        preview.setTheme(theme)
        if stopped() { return }

        let rendered = await preview.renderForExport(source, assetAccess: assetAccess)
        if stopped() { return }
        let renderID: Int
        switch rendered {
        case let .completed(completed):
            renderID = completed
        case let .failed(reason, _):
            onFailure?(Self.explain(reason))
            return
        }

        let html = await preview.exportHTML(matchingRenderID: renderID)
        if stopped() { return }
        guard case let .ready(markup, _, _) = html else {
            if case let .failed(reason, _, _) = html {
                onFailure?(Self.explain(reason))
            }
            return
        }

        let bytes: Data
        var notes: [String] = []
        if html.omittedImageCount > 0 {
            let count = html.omittedImageCount
            notes.append(count == 1
                ? "1 image was replaced with a placeholder."
                : "\(count) images were replaced with placeholders.")
        }
        switch kind {
        case .html:
            bytes = Data(markup.utf8)
        case .pdf, .print:
            status = kind == .print ? "Preparing to print…" : "Creating PDF…"
            let aspect: CGFloat? = kind == .print ? IOSPrintPage.defaultImageableAspect() : nil
            if let aspect { onPrintAspect?(aspect) }
            do {
                let document = try await preview.captureExportPDF(pageAspect: aspect)
                if stopped() { return }
                guard !document.data.isEmpty else {
                    onFailure?("The PDF was empty.")
                    return
                }
                bytes = document.data
                if !document.shrunkPages.isEmpty {
                    notes.append("Some wide pages were scaled down to fit the PDF page limit.")
                }
            } catch let error as ExportPDFCaptureError {
                if !stopped() { onFailure?(Self.explain(error)) }
                return
            } catch is CancellationError {
                return
            } catch {
                if !stopped() { onFailure?("The PDF could not be created. Try again.") }
                return
            }
        }

        // Frontmatter parsing stays off the main actor, as on the Mac.
        let text = source.text
        let fileURL = source.fileURL
        let pathExtension = kind.pathExtension
        let name = await Task.detached(priority: .userInitiated) {
            IOSExportFileName.make(source: text, fileURL: fileURL, pathExtension: pathExtension)
        }.value
        if stopped() { return }
        filename = name
        contentType = kind.contentType
        let note = notes.joined(separator: " ")
        if kind == .print {
            let jobName = (name as NSString).deletingPathExtension
            let visibleJob = jobName.isEmpty ? name : jobName
            if let presentPrintOverride {
                presentPrintOverride(bytes, visibleJob, note)
            } else {
                presentPrint(bytes, jobName: visibleJob, note: note)
            }
            return
        }
        file = IOSExportedFileDocument(data: bytes)
        completionNote = note
        isPresented = true
    }

    private func presentPrint(_ data: Data, jobName: String, note: String) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = jobName
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true) { [weak self] _, completed, error in
            if let error {
                self?.onFailure?(error.localizedDescription)
                return
            }
            guard completed, !note.isEmpty else { return }
            self?.onNote?(note)
        }
    }

    private static func explain(_ reason: String) -> String {
        switch reason {
        case "cancelled":
            "The export was cancelled."
        case "timeout":
            "The preview took too long to prepare. Try again."
        case "stale-or-missing-render":
            "The preview was not ready to export. Try again."
        case "invalidated", "web-content-terminated":
            "The export was interrupted. Try again."
        default:
            "The export could not be completed. Try again."
        }
    }

    private static func explain(_ error: ExportPDFCaptureError) -> String {
        switch error {
        case .invalidated, .webContentProcessTerminated:
            "The export was interrupted. Try again."
        case .geometryUnstable:
            "The page layout did not settle. Try again."
        case .oversizeAtomicBox:
            "A diagram, image, or formula is taller than one PDF page."
        case .oversizeCaptureArea:
            "A page is too large to export as PDF."
        case .breakCrossesPositionedContent:
            "A page break would cut through content that cannot be split."
        case .pageCountMismatch:
            "The PDF pages did not match the layout. Try again."
        case .emptyDocument:
            "The PDF was empty."
        case .captureFailed:
            "The PDF could not be created. Try again."
        }
    }
}

/// Gives the offscreen web view a real size. PDF measurement refuses a zero frame.
@MainActor
private final class IOSExportPreviewHost {
    private let webView: WKWebView
    private var window: UIWindow?

    init(webView: WKWebView) {
        self.webView = webView
        let frame = CGRect(x: 0, y: 0, width: 800, height: 1100)
        webView.frame = frame
        let window = UIWindow(frame: frame)
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .unattached })
        {
            window.windowScene = scene
        }
        let root = UIViewController()
        window.rootViewController = root
        window.windowLevel = .normal - 1
        window.alpha = 0
        window.isHidden = false
        root.view.addSubview(webView)
        webView.frame = root.view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.window = window
    }

    func remove() {
        webView.removeFromSuperview()
        window?.isHidden = true
        window = nil
    }
}
