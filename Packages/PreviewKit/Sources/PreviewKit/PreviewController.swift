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
    var externalURLOpenerOverrideForTesting: (@MainActor (URL) -> Void)?
    var onNavigationDecisionForTesting: (@MainActor (URL?, WKNavigationActionPolicy) -> Void)?

    let assetSchemeHandler: AssetURLSchemeHandler
    let eventHub = PreviewEventHub()
    private let scriptMessageProxy: ScriptMessageProxy
    let previewIndexURL: URL?
    let initialReadinessScheduler: PreviewInitialReadiness.Scheduler
    let retriesSilentInitialLoad: Bool
    var readinessProbeOverrideForTesting: (@MainActor (@escaping @MainActor (Any?) -> Void) -> Void)?
    let pageLoadOverrideForTesting: (@MainActor (WKWebView, URL?) -> WKNavigation?)?
    var initialReadiness = PreviewInitialReadiness()
    var pageLoadGeneration = UUID()
    var currentPageNavigation: WKNavigation?
    private let jsonEncoder = JSONEncoder()
    /// Single-flight render state: at most one render in JavaScript, the newest pending.
    var renderDispatch = PreviewRenderDispatch()
    /// Releases a render slot JavaScript never answers: the md pipeline rethrows without
    /// `renderComplete`, and a render JavaScript drops as stale posts nothing.
    var renderWatchdogNanoseconds: UInt64 = 2_000_000_000
    var lastSubmittedRender: PreviewRenderSubmission?
    var assetContextCache: PreviewAssetContextCacheEntry?
    var viewportScrollQueue = PreviewViewportScrollQueue()
    /// Test seam: receives every outgoing bridge message instead of WebKit.
    var bridgeTransportOverrideForTesting: (@MainActor (BridgeMessage, (@MainActor (Bool) -> Void)?) -> Void)?
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
    /// Set when `webViewWebContentProcessDidTerminate` fires; capture steps check it
    /// between awaits so a mid-capture teardown fails typed rather than hanging.
    private(set) var webContentProcessTerminated = false
    /// A live preview reloads its page after a WebContent termination; an export controller
    /// fails its operation instead (`PreviewController+Recovery.swift`).
    let recoversFromWebContentTermination: Bool
    /// Terminations since the last completed render; recovery stops past a small limit.
    var consecutiveWebContentTerminations = 0
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
    private(set) var theme = "system"
    private(set) var allowRemoteImages = false
    /// Export controllers never tell JavaScript that remote images are allowed.
    let locksRemoteImagesOff: Bool
    /// Nil for the export controller, which keeps the blocking list it was created with,
    /// and nil until compilation finishes when this controller had to wait for it.
    var liveRemoteImageRules: PreviewRemoteImageRules?
    var activeContentRuleList: WKContentRuleList?
    /// The blocking list failed to compile. The page stays unloaded so nothing can be fetched.
    @Published public private(set) var remoteImageNetworkUnavailable = false
    /// True while the first compilation is still outstanding. The requested switch is kept
    /// and applied when the lists arrive, so creation does not block the main queue.
    let awaitsRemoteImageRules: Bool
    private(set) var workspaceAssetRootURL: URL?
    var exportAssetRootURL: URL?

    override public convenience init() {
        self.init(previewIndexURL: Self.defaultPreviewIndexURL(), recoversFromWebContentTermination: true)
    }

    init(
        previewIndexURL: URL?,
        contentRuleList: WKContentRuleList? = nil,
        websiteDataStore: WKWebsiteDataStore? = nil,
        assetReader: (any PreviewAssetReading)? = nil,
        recoversFromWebContentTermination: Bool = false,
        retriesSilentInitialLoad: Bool = PreviewInitialReadiness.retriesSilentInitialLoadByDefault,
        initialReadinessScheduler: @escaping PreviewInitialReadiness.Scheduler = PreviewInitialReadiness.schedule,
        pageLoadOverrideForTesting: (@MainActor (WKWebView, URL?) -> WKNavigation?)? = nil,
        remoteImageRules: PreviewRemoteImageRules? = nil,
        locksRemoteImagesOff: Bool = false
    ) {
        let resolvedLiveRules: PreviewRemoteImageRules?
        let installedRule: WKContentRuleList?
        let waitsForRules: Bool
        if let contentRuleList {
            resolvedLiveRules = nil
            installedRule = contentRuleList
            waitsForRules = false
        } else if let remoteImageRules {
            resolvedLiveRules = remoteImageRules
            installedRule = remoteImageRules.blockAll
            waitsForRules = false
        } else if let cached = PreviewRemoteImageRuleStore.cachedRules() {
            resolvedLiveRules = cached
            installedRule = cached.blockAll
            waitsForRules = false
        } else {
            resolvedLiveRules = nil
            installedRule = nil
            waitsForRules = true
        }
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

        let configuration = Self.webViewConfiguration(
            assetSchemeHandler: assetSchemeHandler,
            bridgeHandler: scriptMessageProxy,
            contentRuleList: installedRule,
            websiteDataStore: websiteDataStore
        )

        webView = WKWebView(frame: .zero, configuration: configuration)
        self.assetSchemeHandler = assetSchemeHandler
        self.scriptMessageProxy = scriptMessageProxy
        self.previewIndexURL = previewIndexURL
        self.recoversFromWebContentTermination = recoversFromWebContentTermination
        self.initialReadinessScheduler = initialReadinessScheduler
        self.retriesSilentInitialLoad = retriesSilentInitialLoad
        self.pageLoadOverrideForTesting = pageLoadOverrideForTesting
        liveRemoteImageRules = resolvedLiveRules
        activeContentRuleList = installedRule
        self.locksRemoteImagesOff = locksRemoteImagesOff
        awaitsRemoteImageRules = waitsForRules
        let blockListMissing = !waitsForRules && contentRuleList == nil && installedRule == nil

        super.init()

        scriptMessageProxy.delegate = self
        webView.navigationDelegate = self
        PreviewPlatform.configureTransparentBackground(webView)
        assetSchemeHandler.onCurrentFailure = { [weak self] failure in
            self?.emitPreviewEvent(.failed(failure))
        }
        if blockListMissing {
            reportRemoteImageNetworkUnavailable()
        } else if waitsForRules {
            PreviewRemoteImageRuleStore.whenReady { [weak self] rules in
                self?.applyCompiledRemoteImageRules(rules)
            }
        } else {
            loadPreviewPage()
            startInitialReadinessWatchdog()
        }
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

    /// Renders a session's text unless this exact presentation was the last one submitted.
    /// Showing the pane or switching documents renders at once, and the restarted
    /// `observe(_:)` yields the same text again ~150 ms later; that repeat would run the
    /// whole pipeline again under a new render ID and hold back pending navigation.
    public func render(_ change: DocumentTextChange, for session: DocumentSession? = nil) {
        if let session, isAlreadySubmitted(change, session: session) {
            return
        }
        _ = submitRender(change, session: session)
    }

    @discardableResult
    func renderForTesting(_ change: DocumentTextChange) -> Int {
        submitRender(change)
    }

    func submitRender(_ change: DocumentTextChange, session: DocumentSession? = nil) -> Int {
        guard !isInvalidated else { return -1 }
        let assetContext = cachedAssetContext(fileURL: change.fileURL)
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
        // Provenance names the newest submitted render, as before single-flight: a pending
        // render that a newer one replaces is never sent, so no DOM can carry its ID.
        checkboxSession = session
        checkboxRenderID = renderID
        checkboxVersion = change.version
        iosDocumentIdentity = identity
        lastSubmittedRender = session.map { renderSubmission(change, session: $0, renderID: renderID) }
        scrollDeliveryState.registerRender(
            renderID,
            documentIdentifier: presentedDocumentIdentifier
                ?? change.fileURL?.standardizedFileURL.absoluteString
        )
        enqueueRender(PreviewRenderRequest(
            change: change,
            renderID: renderID,
            baseDir: assetContext.baseDir,
            assetRootID: assetRootID
        ))
        return renderID
    }

    /// An unchanged value sends nothing: JavaScript already applied it (every render and
    /// `ready` carry the current pair), and each `setTheme` rewrites every image source.
    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        finishInitialReadinessWatchdog()
        invalidatePageReadiness()
        isReady = false
        resetRenderDispatch(keepingPending: false)
        viewportScrollQueue.reset()
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
        if let bridgeTransportOverrideForTesting {
            bridgeTransportOverrideForTesting(message, completion)
            return
        }
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
}

extension PreviewController {
    func receive(_ message: BridgeMessage) {
        switch message {
        case let .ready(payload):
            guard payload.protocolVersion == PreviewBridge.protocolVersion else { return }
            if initialReadiness.requiresRetryProbe {
                // A nil navigation has no matching didFinish to await. Probe the
                // current page instead of trusting a possibly queued old-page ready.
                if currentPageNavigation == nil {
                    probePageReadiness()
                }
                return
            }
            markReadyAndFlushPendingRender()

        case let .renderComplete(payload):
            if scrollDeliveryState.recordRenderCompletion(payload.renderID) {
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
                noteRenderCompletedForRecovery()
            }
            // A superseded render still frees the slot the newer pending render waits on.
            renderDidSettle(payload.renderID)

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

    private func markReadyAndFlushPendingRender() {
        guard !isInvalidated else { return }
        finishInitialReadinessWatchdog()
        let becameReady = !isReady
        isReady = true
        if becameReady {
            emitPreviewEvent(.ready)
        }
        if renderDispatch.pending != nil {
            dispatchPendingRenderIfIdle()
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
            if let externalURLOpenerOverrideForTesting {
                externalURLOpenerOverrideForTesting(url)
            } else {
                PreviewPlatform.openExternalURL(url)
            }
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

public extension PreviewController {
    func setTheme(_ theme: String) {
        guard theme != self.theme else { return }
        self.theme = theme
        sendPreviewSettings()
    }

    func setAllowsRemoteImages(_ allowRemoteImages: Bool) {
        if locksRemoteImagesOff {
            return
        }
        if awaitsRemoteImageRules, liveRemoteImageRules == nil {
            self.allowRemoteImages = allowRemoteImages
            return
        }
        let enforced = enforcedRemoteImageAllowance(allowRemoteImages)
        guard enforced != self.allowRemoteImages else { return }
        self.allowRemoteImages = enforced
        sendPreviewSettings()
    }

    func setWorkspaceAssetRoot(_ rootURL: URL?) {
        workspaceAssetRootURL = rootURL?.standardizedFileURL
    }

    // Permanently releases bridge callbacks and pending work. The owner of a dedicated
    // offscreen export controller must call this when the operation ends.
}

extension PreviewController: WKNavigationDelegate {
    public func webViewWebContentProcessDidTerminate(_: WKWebView) {
        finishInitialReadinessWatchdog()
        initialReadiness.requiresRetryProbe = false
        invalidatePageReadiness()
        isReady = false
        webContentProcessTerminated = true
        // The newest render the page showed or was about to show; a recovering controller
        // re-submits it to the reloaded page.
        let newestRender = renderDispatch.pending ?? renderDispatch.lastSent
        // The in-flight render and any queued viewport scroll died with the process.
        resetRenderDispatch(keepingPending: !recoversFromWebContentTermination)
        viewportScrollQueue.reset()
        failPendingExportWork(reason: "web-content-process-terminated")
        scrollDeliveryState.failPendingDelivery()
        scrollDeliveryState = PreviewScrollDeliveryState()
        recoverFromWebContentTermination(resubmitting: newestRender)
    }

    public func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let policy = Self.navigationPolicy(for: navigationAction.request.url, previewIndexURL: previewIndexURL)
        onNavigationDecisionForTesting?(navigationAction.request.url, policy)
        decisionHandler(policy)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        guard !retriesSilentInitialLoad || currentPageNavigation == nil
            || navigation === currentPageNavigation else { return }
        probePageReadiness()
    }

    func probePageReadiness() {
        guard !isInvalidated, !webContentProcessTerminated else { return }
        let generation = pageLoadGeneration
        let accept: @MainActor (Any?) -> Void = { [weak self] result in
            self?.receiveReadinessProbe(result, generation: generation)
        }
        if let readinessProbeOverrideForTesting {
            readinessProbeOverrideForTesting(accept)
        } else {
            let script = "window.PlainsongPreview && window.PlainsongPreview.PROTOCOL_VERSION"
            webView.evaluateJavaScript(script) { @MainActor result, _ in accept(result) }
        }
    }

    /// The asynchronous probe belongs to the page that issued it, not a later reload.
    func receiveReadinessProbe(_ result: Any?, generation: UUID) {
        guard generation == pageLoadGeneration,
              let version = Self.protocolVersion(from: result),
              version == PreviewBridge.protocolVersion else { return }
        initialReadiness.requiresRetryProbe = false
        markReadyAndFlushPendingRender()
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
    func loadPreviewIndex(indexURL: URL?) -> WKNavigation? {
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

/// Same file as the class: re-submission sets its private provenance fields.
extension PreviewController {
    /// Sends `request`'s text again under a new render ID, keeping its session, version and
    /// iOS identity, so the scroll/export barrier and checkbox provenance name the render
    /// the reloaded page shows.
    func resubmitRender(_ request: PreviewRenderRequest) {
        guard !isInvalidated else { return }
        let renderID = nextRenderID
        nextRenderID += 1
        checkboxRenderID = renderID
        lastSubmittedRender = checkboxSession.map {
            renderSubmission(request.change, session: $0, renderID: renderID)
        }
        scrollDeliveryState.registerRender(
            renderID,
            documentIdentifier: presentedDocumentIdentifier
                ?? request.change.fileURL?.standardizedFileURL.absoluteString
        )
        enqueueRender(PreviewRenderRequest(
            change: request.change,
            renderID: renderID,
            baseDir: request.baseDir,
            assetRootID: request.assetRootID
        ))
    }

    /// File-private: `PreviewRemoteImageRules` is internal, so a public method cannot take it.
    private func applyCompiledRemoteImageRules(_ rules: PreviewRemoteImageRules) {
        guard !isInvalidated, liveRemoteImageRules == nil else { return }
        liveRemoteImageRules = rules
        let allowed = allowRemoteImages && rules.httpsImages != nil && rules.blockAll != nil
        allowRemoteImages = allowed
        guard let rule = rules.rule(allowingHTTPSImages: allowed) else {
            reportRemoteImageNetworkUnavailable()
            return
        }
        webView.configuration.userContentController.add(rule)
        activeContentRuleList = rule
        loadPreviewPage()
        startInitialReadinessWatchdog()
    }

    func reportRemoteImageNetworkUnavailable() {
        remoteImageNetworkUnavailable = true
        emitPreviewEvent(.contentRuleUnavailable)
    }

    func loadPreviewPage(stoppingCurrentLoad: Bool = false) {
        // Fail closed: never parse the page while no content rule is installed.
        // The first controller compiles asynchronously, and a reload during that
        // wait must not open a window with the static `img-src https:` CSP alone.
        guard activeContentRuleList != nil, !remoteImageNetworkUnavailable else { return }
        pageLoadGeneration = UUID()
        currentPageNavigation = nil
        if stoppingCurrentLoad {
            webView.stopLoading()
        }
        if let pageLoadOverrideForTesting {
            currentPageNavigation = pageLoadOverrideForTesting(webView, previewIndexURL)
        } else {
            currentPageNavigation = webView.loadPreviewIndex(indexURL: previewIndexURL)
        }
    }

    func invalidatePageReadiness() {
        pageLoadGeneration = UUID()
        currentPageNavigation = nil
    }

    func reloadPreviewPageAfterTermination() {
        webContentProcessTerminated = false
        loadPreviewPage()
    }
}
