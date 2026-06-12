import Foundation
import UniformTypeIdentifiers
@preconcurrency import WebKit

final class AssetURLSchemeHandler: NSObject, WKURLSchemeHandler {
    private let state = AssetURLSchemeHandlerState()
    private let readQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Plainsong.asset-url-read"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func updateAllowedRoot(_ root: URL?) {
        state.updateAllowedRoot(root)
    }

    func webView(_: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, error: URLError(.badURL))
            return
        }

        guard let root = state.currentAllowedRoot() else {
            fail(urlSchemeTask, error: CocoaError(.fileReadNoPermission))
            return
        }

        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        let task = AssetURLSchemeTaskBox(urlSchemeTask)
        state.clearStoppedTask(taskID)
        let callbackQueue = OperationQueue.current ?? .main
        let state = state

        readQueue.addOperation {
            let result = Result {
                let fileURL = try AssetURLResolver(allowedRoot: root).resolve(url)
                let data = try Data(contentsOf: fileURL)
                let response = URLResponse(
                    url: url,
                    mimeType: Self.mimeType(for: fileURL),
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                return (response, data)
            }

            callbackQueue.addOperation { [state] in
                guard !state.consumeStoppedTask(taskID) else { return }
                switch result {
                case let .success((response, data)):
                    task.didReceive(response)
                    task.didReceive(data)
                    task.didFinish()
                case let .failure(error):
                    task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        state.markStoppedTask(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    private func fail(_ task: WKURLSchemeTask, error: Error) {
        task.didFailWithError(error)
    }

    private nonisolated static func mimeType(for fileURL: URL) -> String {
        UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

private final class AssetURLSchemeHandlerState: @unchecked Sendable {
    private let lock = NSLock()
    private var allowedRoot: URL?
    private var stoppedTaskIDs: Set<ObjectIdentifier> = []

    func updateAllowedRoot(_ root: URL?) {
        lock.lock()
        allowedRoot = root
        lock.unlock()
    }

    func currentAllowedRoot() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return allowedRoot
    }

    func clearStoppedTask(_ taskID: ObjectIdentifier) {
        lock.lock()
        stoppedTaskIDs.remove(taskID)
        lock.unlock()
    }

    func markStoppedTask(_ taskID: ObjectIdentifier) {
        lock.lock()
        stoppedTaskIDs.insert(taskID)
        lock.unlock()
    }

    func consumeStoppedTask(_ taskID: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedTaskIDs.remove(taskID) != nil
    }
}

private struct AssetURLSchemeTaskBox: @unchecked Sendable {
    private let task: any WKURLSchemeTask

    init(_ task: any WKURLSchemeTask) {
        self.task = task
    }

    func didReceive(_ response: URLResponse) {
        task.didReceive(response)
    }

    func didReceive(_ data: Data) {
        task.didReceive(data)
    }

    func didFinish() {
        task.didFinish()
    }

    func didFailWithError(_ error: Error) {
        task.didFailWithError(error)
    }
}
