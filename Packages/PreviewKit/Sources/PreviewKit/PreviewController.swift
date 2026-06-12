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
    public var onCheckboxToggled: ((Int, Bool) -> Void)?

    private let assetSchemeHandler: AssetURLSchemeHandler
    private let scriptMessageProxy: ScriptMessageProxy
    private let jsonEncoder = JSONEncoder()
    private var queuedRender: RenderPayload?
    private var latestRequestedVersion = -1
    private var latestCompletedVersion = -1
    private var theme = "system"

    override public init() {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        let assetSchemeHandler = AssetURLSchemeHandler()
        let scriptMessageProxy = ScriptMessageProxy()

        userContentController.add(scriptMessageProxy, name: "bridge")
        configuration.userContentController = userContentController
        configuration.setURLSchemeHandler(assetSchemeHandler, forURLScheme: "asset")
        configuration.preferences.isElementFullscreenEnabled = false

        webView = WKWebView(frame: .zero, configuration: configuration)
        self.assetSchemeHandler = assetSchemeHandler
        self.scriptMessageProxy = scriptMessageProxy

        super.init()

        scriptMessageProxy.delegate = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.loadPreviewIndex()
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
        assetSchemeHandler.updateAllowedRoot(change.fileURL?.deletingLastPathComponent())

        let payload = RenderPayload(change: change, theme: theme)
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

    private func send(_ message: BridgeMessage) {
        guard let source = try? jsonEncoder.encode(message),
              let json = String(data: source, encoding: .utf8)
        else {
            return
        }

        webView.evaluateJavaScript("window.BlogEditorBridge.receive(\(json));")
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
            onCheckboxToggled?(payload.line, payload.checked)

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
    public func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        let protocolVersionScript = "window.BlogEditorPreview && window.BlogEditorPreview.PROTOCOL_VERSION"
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

private extension PreviewController {
    nonisolated static func protocolVersion(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }

        return value as? Int
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
    func loadPreviewIndex() {
        if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "preview") {
            loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        } else {
            loadHTMLString(
                """
                <!doctype html><meta charset="utf-8"><main id="preview-root"></main>
                <script>window.BlogEditorBridge={receive:function(){}}</script>
                """,
                baseURL: nil
            )
        }
    }
}
