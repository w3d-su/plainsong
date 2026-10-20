import AppKit
import Combine
import Foundation
import MarkdownCore
@preconcurrency import WebKit

@MainActor
public final class PreviewController: NSObject, ObservableObject {
    @Published public private(set) var isReady = false

    public let webView: WKWebView
    public var onPreviewScrolled: ((Int) -> Void)?
    public var onLinkClicked: ((String) -> Void)?
    public var onCheckboxToggled: ((Int, Bool, Int, DocumentSession) -> Void)?
    var renderCompletionObserver: ((RenderCompletePayload) -> Void)?

    private let assetSchemeHandler: AssetURLSchemeHandler
    private let scriptMessageProxy: ScriptMessageProxy
    let previewIndexURL: URL?
    private let jsonEncoder = JSONEncoder()
    private var queuedRender: RenderPayload?
    var scrollDeliveryState = PreviewScrollDeliveryState()
    var presentedDocumentIdentifier: String?
    private weak var checkboxSession: DocumentSession?
    private var checkboxRenderID: Int?
    private var checkboxVersion: Int?
    private var nextRenderID = 0
    var nextExportID = 0
    var exportSourceText = ""
    var exportTimeoutNanoseconds: UInt64 = 15_000_000_000
    private(set) var isInvalidated = false
    /// Set when `webViewWebContentProcessDidTerminate` fires; capture steps check it
    /// between awaits so a mid-capture teardown fails typed rather than hanging.
    private(set) var webContentProcessTerminated = false
    /// Test seam for `captureExportPDF`: invoked with the page index before each page
    /// capture so hosted tests can inject errors, cancellation, or record weak refs.
    var exportPDFCaptureWillCaptureHook: (@MainActor (Int) async throws -> Void)?
    /// Test seam for `captureExportPDF`: replaces the piece joiner so hosted tests
    /// can drive the joined-count check (`pageCountMismatch`).
    var exportPDFPageJoiner: (
        @Sendable ([Data], [CGFloat]) throws -> (data: Data, pageScales: [CGFloat])
    )?
    var pendingHTMLExport: PendingHTMLExport?
    var pendingExportRender: PendingExportRender?
    private var theme = "system"
    private var allowRemoteImages = false
    private var workspaceAssetRootURL: URL?
    var exportAssetRootURL: URL?

    override public convenience init() {
        self.init(previewIndexURL: Self.defaultPreviewIndexURL())
    }

    init(
        previewIndexURL: URL?,
        contentRuleList: WKContentRuleList? = nil,
        websiteDataStore: WKWebsiteDataStore? = nil
    ) {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        let assetSchemeHandler = AssetURLSchemeHandler()
        let scriptMessageProxy = ScriptMessageProxy()
        let previewIndexURL = previewIndexURL?.standardizedFileURL

        userContentController.add(scriptMessageProxy, name: "bridge")
        if let contentRuleList { userContentController.add(contentRuleList) }
        if let websiteDataStore { configuration.websiteDataStore = websiteDataStore }
        configuration.userContentController = userContentController
        configuration.setURLSchemeHandler(assetSchemeHandler, forURLScheme: "asset")
        configuration.preferences.isElementFullscreenEnabled = false

        webView = WKWebView(frame: .zero, configuration: configuration)
        self.assetSchemeHandler = assetSchemeHandler
        self.scriptMessageProxy = scriptMessageProxy
        self.previewIndexURL = previewIndexURL

        super.init()

        scriptMessageProxy.delegate = self
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.loadPreviewIndex(indexURL: previewIndexURL)
    }

    public func observe(_ session: DocumentSession, debounceNanoseconds: UInt64 = 150_000_000) async {
        var pendingRenderTask: Task<Void, Never>?
        defer { pendingRenderTask?.cancel() }

        for await change in session.textChanges() {
            pendingRenderTask?.cancel()
            pendingRenderTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                self?.render(change, for: session)
            }
        }
    }

    public func render(_ change: DocumentTextChange, for session: DocumentSession? = nil) {
        _ = submitRender(change, session: session)
    }

    @discardableResult
    func renderForTesting(_ change: DocumentTextChange) -> Int {
        submitRender(change)
    }

    func submitRender(_ change: DocumentTextChange, session: DocumentSession? = nil) -> Int {
        guard !isInvalidated else { return -1 }
        exportSourceText = change.text
        let assetContext = Self.assetContext(
            fileURL: change.fileURL,
            workspaceRootURL: workspaceAssetRootURL
        )
        exportAssetRootURL = assetContext.allowedRoot
        let assetRootID = assetSchemeHandler.updateAllowedRoot(assetContext.allowedRoot)

        failPendingExportWork(reason: "render-superseded")

        let renderID = nextRenderID
        nextRenderID += 1
        checkboxSession = session
        checkboxRenderID = renderID
        checkboxVersion = change.version
        let payload = RenderPayload(
            change: change,
            renderID: renderID,
            theme: theme,
            allowRemoteImages: allowRemoteImages,
            baseDir: assetContext.baseDir,
            assetRootID: assetRootID
        )
        scrollDeliveryState.registerRender(
            renderID,
            documentIdentifier: presentedDocumentIdentifier
                ?? change.fileURL?.standardizedFileURL.absoluteString
        )

        guard isReady else {
            queuedRender = payload
            return renderID
        }

        send(.render(payload))
        return renderID
    }

    public func setTheme(_ theme: String) {
        self.theme = theme
        sendPreviewSettings()
    }

    public func setAllowsRemoteImages(_ allowRemoteImages: Bool) {
        self.allowRemoteImages = allowRemoteImages
        sendPreviewSettings()
    }

    public func setWorkspaceAssetRoot(_ rootURL: URL?) {
        workspaceAssetRootURL = rootURL?.standardizedFileURL
    }

    /// Permanently releases bridge callbacks and pending work. The owner of a dedicated
    /// offscreen export controller must call this when the operation ends.
    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        isReady = false
        queuedRender = nil
        exportSourceText = ""
        exportAssetRootURL = nil
        scrollDeliveryState.failPendingDelivery()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
        scriptMessageProxy.delegate = nil
        onPreviewScrolled = nil
        onLinkClicked = nil
        onCheckboxToggled = nil
        renderCompletionObserver = nil
        failPendingExportWork(reason: "invalidated")
    }

    func shutdownForTesting() {
        invalidate()
    }

    func send(
        _ message: BridgeMessage,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard let source = try? jsonEncoder.encode(message),
              let json = String(data: source, encoding: .utf8)
        else {
            completion?(false)
            return
        }

        let script = "window.PlainsongBridge.receive(\(json));"
        if let completion {
            webView.evaluateJavaScript(script) { _, error in
                completion(error == nil)
            }
        } else {
            webView.evaluateJavaScript(script)
        }
    }

    private func sendPreviewSettings() {
        guard isReady else { return }
        send(.setTheme(SetThemePayload(theme: theme, allowRemoteImages: allowRemoteImages)))
    }

    func receive(_ message: BridgeMessage) {
        switch message {
        case let .ready(payload):
            guard payload.protocolVersion == PreviewBridge.protocolVersion else {
                return
            }
            markReadyAndFlushQueuedRender()

        case let .renderComplete(payload):
            guard scrollDeliveryState.recordRenderCompletion(payload.renderID) else {
                return
            }
            renderCompletionObserver?(payload)
            completePendingExportRender(payload.renderID)
            flushPendingScrollDeliveryIfReady()

        case let .previewScrolled(payload):
            onPreviewScrolled?(payload.topVisibleLine)

        case let .linkClicked(payload):
            openOrReportLink(payload.href)

        case let .checkboxToggled(payload):
            guard payload.renderID == checkboxRenderID,
                  payload.version == checkboxVersion,
                  let session = checkboxSession
            else { return }
            onCheckboxToggled?(payload.line, payload.checked, payload.version, session)

        case let .exportHTMLResult(payload):
            handleExportHTMLResult(payload)

        case .render, .scrollToLine, .setTheme, .exportHTML:
            break
        }
    }

    private func markReadyAndFlushQueuedRender() {
        guard !isInvalidated else { return }
        isReady = true
        if let queuedRender {
            self.queuedRender = nil
            send(.render(queuedRender))
        } else {
            sendPreviewSettings()
        }
    }

    private func openOrReportLink(_ href: String) {
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased() else {
            onLinkClicked?(href)
            return
        }

        switch scheme {
        case "http", "https":
            NSWorkspace.shared.open(url)
            return
        default:
            onLinkClicked?(href)
        }
    }
}

extension PreviewController: WKNavigationDelegate {
    public func webViewWebContentProcessDidTerminate(_: WKWebView) {
        isReady = false
        webContentProcessTerminated = true
        failPendingExportWork(reason: "web-content-process-terminated")
        scrollDeliveryState.failPendingDelivery()
        scrollDeliveryState = PreviewScrollDeliveryState()
    }

    public func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let policy = Self.navigationPolicy(for: navigationAction.request.url, previewIndexURL: previewIndexURL)
        decisionHandler(policy)
    }

    public func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        let protocolVersionScript = "window.PlainsongPreview && window.PlainsongPreview.PROTOCOL_VERSION"
        webView.evaluateJavaScript(protocolVersionScript) { @MainActor [weak self] result, _ in
            guard let version = PreviewController.protocolVersion(from: result),
                  version == PreviewBridge.protocolVersion
            else {
                return
            }

            self?.markReadyAndFlushQueuedRender()
        }
    }
}

extension PreviewController {
    nonisolated static func defaultPreviewIndexURL() -> URL? {
        Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "preview"
        )?.standardizedFileURL
    }

    nonisolated static func navigationPolicy(for url: URL?, previewIndexURL: URL?) -> WKNavigationActionPolicy {
        guard let url = url?.standardizedFileURL,
              let previewIndexURL = previewIndexURL?.standardizedFileURL,
              url.isFileURL,
              url == previewIndexURL
        else {
            return .cancel
        }

        return .allow
    }
}

private extension PreviewController {
    nonisolated static func protocolVersion(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }

        return value as? Int
    }
}

private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

private extension WKWebView {
    func loadPreviewIndex(indexURL: URL?) {
        if let indexURL {
            loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        } else {
            loadHTMLString(
                """
                <!doctype html><meta charset="utf-8"><main id="preview-root"></main>
                <script>window.PlainsongBridge={receive:function(){}}</script>
                """,
                baseURL: nil
            )
        }
    }
}
