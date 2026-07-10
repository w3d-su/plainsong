import Foundation
import MarkdownCore
@preconcurrency import WebKit

enum AssetURLPolicyError: Error, Equatable {
    case unsupportedType(String)
    case missingFileSize
    case fileTooLarge(actualBytes: Int64, maxBytes: Int64)
}

struct AssetURLPolicyResult: Equatable {
    let mimeType: String
    let data: Data
}

enum AssetURLPolicy {
    static let maxAssetBytes = MarkdownImageAssetPolicy.maximumFileSizeBytes

    static func loadAsset(at fileURL: URL) throws -> AssetURLPolicyResult {
        let mimeType = try mimeType(for: fileURL)
        try validateSize(for: fileURL)

        let data = try Data(contentsOf: fileURL)
        try validateSize(Int64(data.count))

        return AssetURLPolicyResult(mimeType: mimeType, data: data)
    }

    static func mimeType(for fileURL: URL) throws -> String {
        let pathExtension = fileURL.pathExtension.lowercased()
        guard let mimeType = MarkdownImageAssetPolicy.mimeType(forPathExtension: pathExtension) else {
            throw AssetURLPolicyError.unsupportedType(pathExtension)
        }

        return mimeType
    }

    private static func validateSize(for fileURL: URL) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            throw AssetURLPolicyError.missingFileSize
        }

        try validateSize(Int64(fileSize))
    }

    private static func validateSize(_ byteCount: Int64) throws {
        guard byteCount <= maxAssetBytes else {
            throw AssetURLPolicyError.fileTooLarge(
                actualBytes: byteCount,
                maxBytes: maxAssetBytes
            )
        }
    }
}

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
                let asset = try AssetURLPolicy.loadAsset(at: fileURL)
                let response = URLResponse(
                    url: url,
                    mimeType: asset.mimeType,
                    expectedContentLength: asset.data.count,
                    textEncodingName: nil
                )
                return (response, asset.data)
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
