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

/// One user export. HTML and PDF share the Mac offscreen preview: a dedicated
/// controller, remote images forced off, then the existing render barrier.
/// PDF continues into the same page planner and WebKit capture.
@MainActor
final class IOSDocumentExportController: ObservableObject {
    @Published var isPresented = false
    @Published var file: IOSExportedFileDocument?
    @Published var contentType: UTType = .html
    @Published var filename = "Untitled.html"
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?

    private var task: Task<Void, Never>?
    private var completionNote: String?
    var onNote: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    func cancel() {
        task?.cancel()
    }

    func begin(
        _ kind: IOSDocumentExportKind,
        source: DocumentTextChange,
        assetRoot: URL?,
        theme: String,
        assetReader: (any PreviewAssetReading)?
    ) {
        guard !isRunning else { return }
        isRunning = true
        status = kind == .html ? "Preparing HTML…" : "Preparing PDF…"
        task?.cancel()
        task = Task { [weak self] in
            await self?.run(
                kind, source: source, assetRoot: assetRoot, theme: theme, assetReader: assetReader
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

    private func run(
        _ kind: IOSDocumentExportKind,
        source: DocumentTextChange,
        assetRoot: URL?,
        theme: String,
        assetReader: (any PreviewAssetReading)?
    ) async {
        defer {
            isRunning = false
            status = nil
        }
        let preview = PreviewController()
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
        preview.setWorkspaceAssetRoot(assetRoot)
        if Task.isCancelled { return }

        let rendered = await preview.renderForExport(source)
        if Task.isCancelled { return }
        let renderID: Int
        switch rendered {
        case let .completed(completed):
            renderID = completed
        case let .failed(reason, _):
            onFailure?(Self.explain(reason))
            return
        }

        let html = await preview.exportHTML(matchingRenderID: renderID)
        if Task.isCancelled { return }
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
            do {
                let document = try await preview.captureExportPDF()
                if Task.isCancelled { return }
                guard !document.data.isEmpty else {
                    onFailure?("The PDF was empty.")
                    return
                }
                bytes = document.data
                if !document.shrunkPages.isEmpty {
                    notes.append("Some wide pages were scaled down to fit the PDF page limit.")
                }
            } catch let error as ExportPDFCaptureError {
                onFailure?(Self.explain(error))
                return
            } catch is CancellationError {
                return
            } catch {
                onFailure?("The PDF could not be created. Try again.")
                return
            }
        }

        filename = IOSExportFileName.make(
            source: source.text, fileURL: source.fileURL, pathExtension: kind.pathExtension
        )
        contentType = kind.contentType
        let note = notes.joined(separator: " ")
        if kind == .print {
            presentPrint(bytes, jobName: filename, note: note)
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
