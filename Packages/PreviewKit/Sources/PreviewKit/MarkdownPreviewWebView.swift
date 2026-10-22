import SwiftUI
@preconcurrency import WebKit

#if os(macOS)

    public struct MarkdownPreviewWebView: NSViewRepresentable {
        private let controller: PreviewController

        public init(controller: PreviewController) {
            self.controller = controller
        }

        public func makeNSView(context _: Context) -> PreviewWebHostView {
            PreviewWebHostView(webView: controller.webView)
        }

        public func updateNSView(_ nsView: PreviewWebHostView, context _: Context) {
            nsView.attach(webView: controller.webView)
        }
    }

    public final class PreviewWebHostView: NSView {
        private weak var hostedWebView: WKWebView?

        init(webView: WKWebView) {
            super.init(frame: .zero)
            wantsLayer = true
            attach(webView: webView)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        override public var isFlipped: Bool {
            true
        }

        override public var intrinsicContentSize: NSSize {
            NSSize(width: 320, height: 240)
        }

        public func attach(webView: WKWebView) {
            guard hostedWebView !== webView || webView.superview !== self else { return }

            hostedWebView?.removeFromSuperview()
            hostedWebView = webView
            webView.removeFromSuperview()
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
            needsLayout = true
        }

        override public func layout() {
            super.layout()
            hostedWebView?.frame = bounds
        }
    }

#else

    public struct MarkdownPreviewWebView: UIViewRepresentable {
        private let controller: PreviewController

        public init(controller: PreviewController) {
            self.controller = controller
        }

        public func makeUIView(context _: Context) -> PreviewWebHostView {
            PreviewWebHostView(webView: controller.webView)
        }

        public func updateUIView(_ uiView: PreviewWebHostView, context _: Context) {
            uiView.attach(webView: controller.webView)
        }
    }

    public final class PreviewWebHostView: UIView {
        private weak var hostedWebView: WKWebView?

        init(webView: WKWebView) {
            super.init(frame: .zero)
            backgroundColor = .clear
            attach(webView: webView)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        override public var intrinsicContentSize: CGSize {
            CGSize(width: 320, height: 240)
        }

        public func attach(webView: WKWebView) {
            guard hostedWebView !== webView || webView.superview !== self else { return }

            hostedWebView?.removeFromSuperview()
            hostedWebView = webView
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.frame = bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(webView)
            setNeedsLayout()
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            hostedWebView?.frame = bounds
        }
    }

#endif
