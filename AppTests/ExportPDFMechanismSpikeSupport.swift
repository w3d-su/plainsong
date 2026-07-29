import AppKit
import Foundation
import MarkdownCore
@testable import PreviewKit
import WebKit

@MainActor
final class E0OffscreenPDFProbe {
    static let exportViewport = CGSize(width: 800, height: 600)

    let controller: PreviewController
    private(set) var completedRenders: [Int: RenderCompletePayload] = [:]

    init() {
        controller = PreviewController()
        configureController()
    }

    init(previewIndexURL: URL?) {
        controller = PreviewController(previewIndexURL: previewIndexURL)
        configureController()
    }

    func waitUntilReady(timeoutNanoseconds: UInt64 = 5_000_000_000) async throws {
        try await waitUntil("offscreen preview bridge ready", timeoutNanoseconds: timeoutNanoseconds) {
            self.controller.isReady
        }
    }

    func render(
        text: String,
        fileKind: FileKind,
        version: Int,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async throws -> E0SubmittedRender {
        try await waitUntilReady(timeoutNanoseconds: timeoutNanoseconds)
        try Task.checkCancellation()

        let submittedRenderID = controller.renderForTesting(
            DocumentTextChange(
                text: text,
                version: version,
                fileKind: fileKind,
                fileURL: nil
            )
        )

        try await waitUntil(
            "renderComplete for renderID \(submittedRenderID)",
            timeoutNanoseconds: timeoutNanoseconds
        ) {
            self.completedRenders[submittedRenderID] != nil
        }

        guard let completion = completedRenders[submittedRenderID] else {
            throw E0ProbeError.missingRenderCompletion(submittedRenderID)
        }
        return E0SubmittedRender(submittedRenderID: submittedRenderID, completion: completion)
    }

    func domState() async throws -> E0DOMState {
        let script = """
        JSON.stringify({
          text: document.body.innerText,
          html: document.getElementById("preview-root")?.innerHTML ?? "",
          theme: document.documentElement.dataset.theme ?? "",
          stale: document.getElementById("preview-root")?.classList.contains("preview-stale") ?? false,
          scrollY: window.scrollY
        })
        """
        guard let json = try await evaluateJavaScript(script, label: "DOM state") as? String,
              let data = json.data(using: .utf8)
        else {
            throw E0ProbeError.invalidJavaScriptResult("DOM state")
        }
        return try JSONDecoder().decode(E0DOMState.self, from: data)
    }

    func requireSuccessfulCurrentDOM() async throws {
        if try await domState().stale {
            throw E0ProbeError.currentRenderFailed
        }
    }

    func measureFullContentBounds() async throws -> CGRect {
        let script = """
        JSON.stringify({
          width: Math.max(
            document.documentElement.scrollWidth,
            document.body.scrollWidth,
            document.documentElement.clientWidth,
            document.body.clientWidth
          ),
          height: Math.max(
            document.documentElement.scrollHeight,
            document.body.scrollHeight,
            document.documentElement.clientHeight,
            document.body.clientHeight
          )
        })
        """
        guard let json = try await evaluateJavaScript(script, label: "content bounds") as? String,
              let data = json.data(using: .utf8)
        else {
            throw E0ProbeError.invalidJavaScriptResult("content bounds")
        }
        let measurement = try JSONDecoder().decode(E0ContentMeasurement.self, from: data)
        guard measurement.width.isFinite,
              measurement.height.isFinite,
              measurement.width > 0,
              measurement.height > 0
        else {
            throw E0ProbeError.invalidContentBounds(measurement.width, measurement.height)
        }
        return CGRect(x: 0, y: 0, width: measurement.width, height: measurement.height)
    }

    func settleFullContentGeometry(
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws -> E0SettledGeometry {
        let initialViewport = controller.webView.bounds
        guard initialViewport.width > 0, initialViewport.height > 0 else {
            throw E0ProbeError.invalidContentBounds(initialViewport.width, initialViewport.height)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        var previousBounds: CGRect?
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try Task.checkCancellation()
            let measuredBounds = try await measureFullContentBounds()
            controller.webView.frame = measuredBounds
            controller.webView.layoutSubtreeIfNeeded()
            let remeasuredBounds = try await measureFullContentBounds()

            if let previousBounds,
               Self.rectsMatch(previousBounds, remeasuredBounds),
               Self.rectsMatch(controller.webView.bounds, remeasuredBounds)
            {
                return E0SettledGeometry(
                    exportViewport: initialViewport,
                    contentBounds: remeasuredBounds
                )
            }

            previousBounds = remeasuredBounds
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        throw E0ProbeError.timeout("full-content geometry")
    }

    func capturePDF(rect: CGRect) async throws -> E0PDFSnapshot {
        try Task.checkCancellation()
        guard rect.width > 0,
              rect.height > 0,
              controller.webView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect)
        else {
            throw E0ProbeError.captureRectOutsideWebView(rect, controller.webView.bounds)
        }

        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        let data: Data = try await boundedRequest(label: "createPDF") { gate in
            self.controller.webView.createPDF(configuration: configuration) { result in
                gate.resolve(result)
            }
        }
        try Task.checkCancellation()
        return try E0PDFSnapshot(
            data: data,
            configurationRect: E0ProbeError.unwrap(configuration.rect, "WKPDFConfiguration.rect")
        )
    }

    func chooseFixedPaginationHeight(
        contentBounds: CGRect,
        minimumHeight: Int = 6000,
        boundaryClearance: CGFloat = 0.5
    ) async throws -> CGFloat {
        let script = """
        JSON.stringify(Array.from(document.querySelectorAll("#preview-root h3[data-line]")).map(element => {
          const rect = element.getBoundingClientRect();
          return { minY: rect.top + window.scrollY, maxY: rect.bottom + window.scrollY };
        }))
        """
        guard let json = try await evaluateJavaScript(script, label: "pagination block bounds") as? String,
              let data = json.data(using: .utf8)
        else {
            throw E0ProbeError.invalidJavaScriptResult("pagination block bounds")
        }
        let blocks = try JSONDecoder().decode([E0ContentBlockBounds].self, from: data)
        guard !blocks.isEmpty else {
            throw E0ProbeError.invalidJavaScriptResult("empty pagination block bounds")
        }

        for candidate in stride(from: 14400, through: minimumHeight, by: -1) {
            let pageHeight = CGFloat(candidate)
            var boundary = contentBounds.minY + pageHeight
            var isSafe = true
            while boundary < contentBounds.maxY - 0.5 {
                if blocks.contains(where: {
                    boundary >= $0.minY - boundaryClearance
                        && boundary <= $0.maxY + boundaryClearance
                }) {
                    isSafe = false
                    break
                }
                boundary += pageHeight
            }
            if isSafe {
                return pageHeight
            }
        }

        throw E0ProbeError.noSafeFixedPaginationHeight
    }

    func scroll(toY offset: CGFloat) async throws {
        _ = try await evaluateJavaScript("window.scrollTo(0, \(offset))", label: "preview scroll")
    }

    func captureFixedHeightPages(
        contentBounds: CGRect,
        pageHeight: CGFloat = 7200
    ) async throws -> [E0PDFSnapshot] {
        guard pageHeight > 0, pageHeight <= 14400 else {
            throw E0ProbeError.invalidPaginationHeight(pageHeight)
        }

        var pages: [E0PDFSnapshot] = []
        var offset = contentBounds.minY
        while offset < contentBounds.maxY - 0.5 {
            try Task.checkCancellation()
            let height = min(pageHeight, contentBounds.maxY - offset)
            let rect = CGRect(x: contentBounds.minX, y: offset, width: contentBounds.width, height: height)
            do {
                try await pages.append(capturePDF(rect: rect))
            } catch {
                throw E0ProbeError.paginationCaptureFailed(
                    pageIndex: pages.count,
                    rect: rect,
                    underlying: String(describing: error)
                )
            }
            offset += height
        }
        return pages
    }

    func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try Task.checkCancellation()
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw E0ProbeError.timeout(description)
    }

    private func configureController() {
        controller.webView.frame = CGRect(origin: .zero, size: Self.exportViewport)
        controller.setAllowsRemoteImages(false)
        controller.renderCompletionObserver = { [weak self] payload in
            self?.completedRenders[payload.renderID] = payload
        }
    }

    private func evaluateJavaScript(
        _ script: String,
        label: String,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws -> Any? {
        let value: E0JavaScriptValue = try await boundedRequest(
            label: label,
            timeoutNanoseconds: timeoutNanoseconds
        ) { gate in
            self.controller.webView.evaluateJavaScript(script) { result, error in
                if let error {
                    gate.resolve(.failure(error))
                } else {
                    gate.resolve(.success(E0JavaScriptValue(rawValue: result)))
                }
            }
        }
        return value.rawValue
    }

    private func boundedRequest<Value: Sendable>(
        label: String,
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        start: (E0BoundedRequestGate<Value>) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let value = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Value, Error>) in
            let gate = E0BoundedRequestGate(continuation: continuation)
            start(gate)
            Task { @MainActor [weak gate] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                gate?.resolve(.failure(E0ProbeError.timeout(label)))
            }
        }
        try Task.checkCancellation()
        return value
    }

    private static func rectsMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

@MainActor
private final class E0BoundedRequestGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Value, Error>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

private struct E0JavaScriptValue: @unchecked Sendable {
    let rawValue: Any?
}

struct E0SubmittedRender {
    let submittedRenderID: Int
    let completion: RenderCompletePayload
}

struct E0SettledGeometry {
    let exportViewport: CGRect
    let contentBounds: CGRect
}

struct E0DOMState: Codable, Equatable {
    let text: String
    let html: String
    let theme: String
    let stale: Bool
    let scrollY: Double
}

private struct E0ContentMeasurement: Codable {
    let width: Double
    let height: Double
}

private struct E0ContentBlockBounds: Codable {
    let minY: CGFloat
    let maxY: CGFloat
}
