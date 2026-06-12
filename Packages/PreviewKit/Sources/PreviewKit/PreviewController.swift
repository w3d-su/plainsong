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
    public var onCheckboxToggled: ((Int, Bool, Int) -> Void)?

    private let assetSchemeHandler: AssetURLSchemeHandler
    private let scriptMessageProxy: ScriptMessageProxy
    private let previewIndexURL: URL?
    private let jsonEncoder = JSONEncoder()
    private var queuedRender: RenderPayload?
    private var latestRequestedVersion = -1
    private var latestCompletedVersion = -1
    private var theme = "system"
    private var workspaceAssetRootURL: URL?

    override public convenience init() {
        self.init(previewIndexURL: Self.defaultPreviewIndexURL())
    }

    init(previewIndexURL: URL?) {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        let assetSchemeHandler = AssetURLSchemeHandler()
        let scriptMessageProxy = ScriptMessageProxy()
        let previewIndexURL = previewIndexURL?.standardizedFileURL

        userContentController.add(scriptMessageProxy, name: "bridge")
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
                self?.render(change)
            }
        }
    }

    public func render(_ change: DocumentTextChange) {
        let assetContext = Self.assetContext(
            fileURL: change.fileURL,
            workspaceRootURL: workspaceAssetRootURL
        )
        assetSchemeHandler.updateAllowedRoot(assetContext.allowedRoot)

        let payload = RenderPayload(change: change, theme: theme, baseDir: assetContext.baseDir)
        latestRequestedVersion = max(latestRequestedVersion, payload.version)

        guard isReady else {
            queuedRender = payload
            return
        }

        send(.render(payload))
    }

    public func scrollToLine(_ line: Int, animated: Bool) {
        send(.scrollToLine(ScrollToLinePayload(line: line, animated: animated)))
    }

    public func setTheme(_ theme: String) {
        self.theme = theme
        send(.setTheme(SetThemePayload(theme: theme)))
    }

    public func setWorkspaceAssetRoot(_ rootURL: URL?) {
        workspaceAssetRootURL = rootURL?.standardizedFileURL
    }

    private func send(_ message: BridgeMessage) {
        guard let source = try? jsonEncoder.encode(message),
              let json = String(data: source, encoding: .utf8)
        else {
            return
        }

        webView.evaluateJavaScript("window.PlainsongBridge.receive(\(json));")
    }

    private func receive(_ message: BridgeMessage) {
        switch message {
        case let .ready(payload):
            guard payload.protocolVersion == PreviewBridge.protocolVersion else {
                return
            }
            markReadyAndFlushQueuedRender()

        case let .renderComplete(payload):
            guard payload.version >= latestRequestedVersion else {
                return
            }
            latestCompletedVersion = max(latestCompletedVersion, payload.version)

        case let .previewScrolled(payload):
            onPreviewScrolled?(payload.topVisibleLine)

        case let .linkClicked(payload):
            openOrReportLink(payload.href)

        case let .checkboxToggled(payload):
            onCheckboxToggled?(payload.line, payload.checked, payload.version)

        case .render, .scrollToLine, .setTheme:
            break
        }
    }

    private func markReadyAndFlushQueuedRender() {
        isReady = true
        if let queuedRender {
            self.queuedRender = nil
            send(.render(queuedRender))
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
    private nonisolated static func defaultPreviewIndexURL() -> URL? {
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

extension PreviewController: WKScriptMessageHandler {
    public func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bridge",
              JSONSerialization.isValidJSONObject(message.body),
              let data = try? JSONSerialization.data(withJSONObject: message.body),
              let bridgeMessage = try? JSONDecoder().decode(BridgeMessage.self, from: data)
        else {
            return
        }

        receive(bridgeMessage)
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
