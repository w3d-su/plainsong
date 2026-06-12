import Foundation
import UniformTypeIdentifiers
@preconcurrency import WebKit

final class AssetURLSchemeHandler: NSObject, WKURLSchemeHandler {
    private let lock = NSLock()
    private var allowedRoot: URL?

    func updateAllowedRoot(_ root: URL?) {
        lock.lock()
        allowedRoot = root
        lock.unlock()
    }

    func webView(_: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, error: URLError(.badURL))
            return
        }

        guard let root = currentAllowedRoot() else {
            fail(urlSchemeTask, error: CocoaError(.fileReadNoPermission))
            return
        }

        do {
            let fileURL = try AssetURLResolver(allowedRoot: root).resolve(url)
            let data = try Data(contentsOf: fileURL)
            let response = URLResponse(
                url: url,
                mimeType: Self.mimeType(for: fileURL),
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_: WKWebView, stop _: WKURLSchemeTask) {}

    private func currentAllowedRoot() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return allowedRoot
    }

    private func fail(_ task: WKURLSchemeTask, error: Error) {
        task.didFailWithError(error)
    }

    private static func mimeType(for fileURL: URL) -> String {
        UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
