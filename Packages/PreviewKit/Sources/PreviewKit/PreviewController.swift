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

    let assetSchemeHandler: AssetURLSchemeHandler
    let eventHub = PreviewEventHub()
    private let scriptMessageProxy: ScriptMessageProxy
    let previewIndexURL: URL?
    private let jsonEncoder = JSONEncoder()
    private var queuedRender: RenderPayload?
    var scrollDeliveryState = PreviewScrollDeliveryState()
    var presentedDocumentIdentifier: String?
    private weak var checkboxSession: DocumentSession?
    private var checkboxRenderID: Int?
    private var checkboxVersion: Int?
    private var iosDocumentIdentity: IOSDocumentIdentity?
    private var nextRenderID = 0
    var nextExportID = 0
    var exportSourceText = ""
    var exportTimeoutNanoseconds: UInt64 = 15_000_000_000
    private(set) var isInvalidated = false
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
        websiteDataStore: WKWebsiteDataStore? = nil,
        assetReader: (any PreviewAssetReading)? = nil
    ) {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        let assetSchemeHandler = AssetURLSchemeHandler()
        let scriptMessageProxy = ScriptMessageProxy()
        let previewIndexURL = previewIndexURL?.standardizedFileURL
        #if os(macOS)
            assetSchemeHandler.installReader(assetReader ?? DirectPreviewAssetReader())
        #else
            if let assetReader {
                assetSchemeHandler.installReader(assetReader)
            }
        #endif

        userContentController.add(scriptMessageProxy, name: "bridge")
        if let contentRuleList {
            userContentController.add(contentRuleList)
        }
        if let websiteDataStore {
            configuration.websiteDataStore = websiteDataStore
        }
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
        PreviewPlatform.configureTransparentBackground(webView)
        assetSchemeHandler.onCurrentFailure = { [weak self] failure in
            self?.emitPreviewEvent(.failed(failure))
        }
        webView.loadPreviewIndex(indexURL: previewIndexURL)
    }

    /// Injects 06's leased reader. Production iOS composition stays with the integrator.
    /// Passing a reader does not relax PreviewKit's type, size, or containment checks.
    public func installAssetReader(_ reader: any PreviewAssetReading) {
        assetSchemeHandler.installReader(reader)
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
        let assetContext = Self.assetContext(
            fileURL: change.fileURL,
            workspaceRootURL: workspaceAssetRootURL
        )
        let assetRootID = assetSchemeHandler.updateAllowedRoot(assetContext.allowedRoot)
        return prepareRender(
            change,
            session: session,
            identity: nil,
            assetContext: assetContext,
            assetRootID: assetRootID
        )
    }

    func prepareIOSRender(
        _ snapshot: DocumentSnapshot,
        identity: IOSDocumentIdentity,
        assetAccess: PreviewAssetAccessContext?
    ) {
        guard !isInvalidated else { return }
        setPresentedDocumentIdentifier(identity.rawValue.uuidString)
        let installation = assetSchemeHandler.updateAuthority(assetAccess)
        if installation.reportsMissingDirectoryGrant {
            emitPreviewEvent(.failed(.unavailable))
        }
        let change = DocumentTextChange(
            text: snapshot.text,
            version: snapshot.version,
            fileKind: snapshot.fileKind,
            fileURL: snapshot.fileURL
        )
        _ = prepareRender(
            change,
            session: nil,
            identity: identity,
            assetContext: Self.grantedAssetContext(fileURL: snapshot.fileURL, access: assetAccess),
            assetRootID: installation.token
        )
    }

    func prepareRender(
        _ change: DocumentTextChange,
        session: DocumentSession?,
        identity: IOSDocumentIdentity?,
        assetContext: PreviewAssetContext,
        assetRootID: String
    ) -> Int {
        guard !isInvalidated else { return -1 }
        exportSourceText = change.text
        exportAssetRootURL = assetContext.allowedRoot
        failPendingExportWork(reason: "render-superseded")

        let renderID = nextRenderID
        nextRenderID += 1
        checkboxSession = session
        checkboxRenderID = renderID
        checkboxVersion = change.version
        iosDocumentIdentity = identity
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
        iosDocumentIdentity = nil
        assetSchemeHandler.invalidateReads()
        failPendingExportWork(reason: "invalidated")
    }

    func shutdownForTesting() {
        invalidate()
    }

    var previewProvenanceForTesting: (renderID: Int?, version: Int?, identity: IOSDocumentIdentity?) {
        (checkboxRenderID, checkboxVersion, iosDocumentIdentity)
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
            if let iosDocumentIdentity {
                emitPreviewEvent(.renderCompleted(
                    documentID: iosDocumentIdentity,
                    renderID: payload.renderID,
                    version: payload.version
                ))
            }
            completePendingExportRender(payload.renderID)
            flushPendingScrollDeliveryIfReady()

        case let .previewScrolled(payload):
            onPreviewScrolled?(payload.topVisibleLine)

        case let .linkClicked(payload):
            openOrReportLink(payload.href)

        case let .checkboxToggled(payload):
            guard payload.renderID == checkboxRenderID,
                  payload.version == checkboxVersion
            else { return }
            if let session = checkboxSession {
                onCheckboxToggled?(payload.line, payload.checked, payload.version, session)
            }
            if let iosDocumentIdentity {
                emitPreviewEvent(.checkboxRequested(
                    revision: IOSDocumentRevision(documentID: iosDocumentIdentity, version: payload.version),
                    renderID: payload.renderID,
                    line: payload.line,
                    checked: payload.checked
                ))
            }

        case let .exportHTMLResult(payload):
            handleExportHTMLResult(payload)

        case .render, .scrollToLine, .setTheme, .exportHTML:
            break
        }
    }

    private func markReadyAndFlushQueuedRender() {
        guard !isInvalidated else { return }
        let becameReady = !isReady
        isReady = true
        if becameReady {
            emitPreviewEvent(.ready)
        }
        if let queuedRender {
            self.queuedRender = nil
            send(.render(queuedRender))
        } else {
            sendPreviewSettings()
        }
    }

    private func openOrReportLink(_ href: String) {
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased() else {
            reportRelativeLink(href)
            return
        }

        switch scheme {
        case "http", "https":
            emitPreviewEvent(.externalLinkRequested(url))
            PreviewPlatform.openExternalURL(url)
        default:
            reportRelativeLink(href)
        }
    }

    private func reportRelativeLink(_ href: String) {
        onLinkClicked?(href)
        if let iosDocumentIdentity {
            emitPreviewEvent(.relativeLinkRequested(documentID: iosDocumentIdentity, href: href))
        }
    }
}

extension PreviewController: WKNavigationDelegate {
    public func webViewWebContentProcessDidTerminate(_: WKWebView) {
        isReady = false
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

    nonisolated static func assetContext(fileURL: URL?, workspaceRootURL: URL?) -> PreviewAssetContext {
        guard let fileURL = fileURL?.standardizedFileURL else {
            return PreviewAssetContext(allowedRoot: workspaceRootURL?.standardizedFileURL, baseDir: nil)
        }

        guard let workspaceRootURL = workspaceRootURL?.standardizedFileURL,
              fileURL.isDescendant(of: workspaceRootURL)
        else {
            return PreviewAssetContext(
                allowedRoot: fileURL.deletingLastPathComponent().standardizedFileURL,
                baseDir: nil
            )
        }

        return PreviewAssetContext(
            allowedRoot: workspaceRootURL,
            baseDir: fileURL.deletingLastPathComponent().pathRelative(to: workspaceRootURL)
        )
    }

    /// Directory authority comes only from the supplied grant. A nil grant does not
    /// promote the file parent into an asset root.
    nonisolated static func grantedAssetContext(
        fileURL: URL?,
        access: PreviewAssetAccessContext?
    ) -> PreviewAssetContext {
        guard let access else {
            return PreviewAssetContext(allowedRoot: nil, baseDir: nil)
        }
        guard let fileURL = fileURL?.standardizedFileURL else {
            return PreviewAssetContext(allowedRoot: access.allowedRoot, baseDir: nil)
        }
        return PreviewAssetContext(
            allowedRoot: access.allowedRoot,
            baseDir: fileURL.deletingLastPathComponent().pathRelative(to: access.allowedRoot)
        )
    }
}

struct PreviewAssetContext: Equatable {
    let allowedRoot: URL?
    let baseDir: String?
}

private extension PreviewController {
    nonisolated static func protocolVersion(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }

        return value as? Int
    }
}

private extension URL {
    func isDescendant(of rootURL: URL) -> Bool {
        let candidatePath = standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let rootPath = Self.normalizedDirectoryPath(
            rootURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        )
        return candidatePath == rootPath || candidatePath.hasPrefix("\(rootPath)/")
    }

    func pathRelative(to rootURL: URL) -> String? {
        let rootPath = Self.normalizedDirectoryPath(rootURL.standardizedFileURL.path(percentEncoded: false))
        let candidatePath = standardizedFileURL.path(percentEncoded: false)
        guard candidatePath == rootPath || candidatePath.hasPrefix("\(rootPath)/") else { return nil }

        var relativePath = String(candidatePath.dropFirst(rootPath.count))
        if relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }
        while relativePath.hasSuffix("/") {
            relativePath.removeLast()
        }
        return relativePath.isEmpty ? nil : relativePath
    }

    static func normalizedDirectoryPath(_ path: String) -> String {
        guard path != "/" else { return path }
        var normalized = path
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
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
