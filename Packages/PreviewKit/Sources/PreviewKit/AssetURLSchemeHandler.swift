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

    /// Policy for bytes a reader already returned. The reader cannot skip the
    /// extension allowlist or the post-read byte cap.
    static func deliveredAsset(data: Data, fileURL: URL) throws -> AssetURLPolicyResult {
        let mimeType = try mimeType(for: fileURL)
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

protocol PreviewAssetSchemeTask: AnyObject {
    var requestURL: URL? { get }
    func receive(response: URLResponse)
    func receive(data: Data)
    func finish()
    func fail(_ error: Error)
}

struct AssetAuthorityInstallation: Equatable {
    let token: String
    let reportsMissingDirectoryGrant: Bool
}

final class AssetURLSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let state = AssetURLSchemeHandlerState()
    private let readers = AssetReaderBox()
    var onCurrentFailure: (@MainActor (PreviewAssetReadFailure) -> Void)?

    func installReader(_ reader: (any PreviewAssetReading)?) {
        readers.set(reader)
    }

    @discardableResult
    func updateAllowedRoot(_ root: URL?) -> String {
        state.updateAllowedRoot(root)
    }

    func updateAuthority(_ context: PreviewAssetAccessContext?) -> AssetAuthorityInstallation {
        state.updateAuthority(context)
    }

    func currentPlainsongRootToken() -> String {
        state.currentToken()
    }

    func isCurrent(_ context: PreviewAssetAccessContext) -> Bool {
        state.matches(context)
    }

    func invalidateReads() {
        state.invalidate()
    }

    func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        start(WKAssetSchemeTask(urlSchemeTask), taskID: ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    func webView(_: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        state.stop(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    func stop(_ task: any PreviewAssetSchemeTask) {
        state.stop(ObjectIdentifier(task))
    }

    func start(_ task: any PreviewAssetSchemeTask) {
        start(task, taskID: ObjectIdentifier(task))
    }

    private func start(_ task: any PreviewAssetSchemeTask, taskID: ObjectIdentifier) {
        switch state.begin(url: task.requestURL, taskID: taskID) {
        case .invalidated:
            return
        case .missingURL:
            task.fail(URLError(.badURL))
        case .staleToken:
            task.fail(CocoaError(.fileReadNoPermission))
        case .missingAuthority:
            task.fail(CocoaError(.fileReadNoPermission))
            report(.unavailable, capture: nil, taskID: taskID)
        case let .ready(capture):
            beginRead(task, capture: capture, taskID: taskID)
        }
    }

    private func beginRead(_ task: any PreviewAssetSchemeTask, capture: AssetReadCapture, taskID: ObjectIdentifier) {
        guard let requestURL = task.requestURL else { return }
        let resolved: URL
        do {
            resolved = try AssetURLResolver(allowedRoot: capture.allowedRoot).resolve(requestURL)
            _ = try AssetURLPolicy.mimeType(for: resolved)
            if let fileSize = try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               Int64(fileSize) > AssetURLPolicy.maxAssetBytes
            {
                throw AssetURLPolicyError.fileTooLarge(
                    actualBytes: Int64(fileSize),
                    maxBytes: AssetURLPolicy.maxAssetBytes
                )
            }
        } catch {
            failMapped(task, error: error, capture: capture, taskID: taskID)
            return
        }

        let request = PreviewAssetReadRequest(
            requestID: capture.requestID,
            resolvedURL: resolved,
            access: capture.access,
            maximumByteCount: Int(exactly: AssetURLPolicy.maxAssetBytes) ?? .max
        )
        let reader = readers.current()
        let box = SchemeTaskBox(task)
        let readTask = Task.detached { [weak self] in
            guard let self else { return }
            await finishRead(box, request: request, reader: reader, capture: capture, taskID: taskID)
        }
        state.store(readTask, id: taskID)
    }

    private func finishRead(
        _ box: SchemeTaskBox,
        request: PreviewAssetReadRequest,
        reader: (any PreviewAssetReading)?,
        capture: AssetReadCapture,
        taskID: ObjectIdentifier
    ) async {
        do {
            try Task.checkCancellation()
            guard let reader else {
                await failCurrent(box.task, failure: .unavailable, capture: capture, taskID: taskID)
                return
            }
            let result = try await reader.read(request)
            try Task.checkCancellation()
            await deliver(box.task, result: result, capture: capture, taskID: taskID)
        } catch is CancellationError {
            return
        } catch let failure as PreviewAssetReadFailure {
            await failCurrent(box.task, failure: failure, capture: capture, taskID: taskID)
        } catch {
            await failCurrent(box.task, failure: .providerFailed, capture: capture, taskID: taskID)
        }
    }

    @MainActor
    private func deliver(
        _ task: any PreviewAssetSchemeTask,
        result: PreviewAssetReadResult,
        capture: AssetReadCapture,
        taskID: ObjectIdentifier
    ) {
        let permission = state.permission(for: capture, taskID: taskID)
        guard permission.acceptsDelivery, let root = permission.allowedRoot else { return }
        guard result.requestID == capture.requestID, AssetAuthority.matches(result.access, capture.access) else {
            failCurrentSync(task, failure: .accessChanged, capture: capture, taskID: taskID)
            return
        }

        do {
            let contained = try AssetContainment.fileURL(result.coordinatedURL, isContainedIn: root)
            let asset = try AssetURLPolicy.deliveredAsset(data: result.bytes, fileURL: contained)
            guard state.permission(for: capture, taskID: taskID).acceptsDelivery else { return }
            let response = URLResponse(
                url: task.requestURL ?? contained,
                mimeType: asset.mimeType,
                expectedContentLength: asset.data.count,
                textEncodingName: nil
            )
            task.receive(response: response)
            guard state.permission(for: capture, taskID: taskID).acceptsDelivery else { return }
            task.receive(data: asset.data)
            guard state.permission(for: capture, taskID: taskID).acceptsDelivery else { return }
            task.finish()
        } catch {
            failMapped(task, error: error, capture: capture, taskID: taskID)
        }
    }

    @MainActor
    private func failCurrent(
        _ task: any PreviewAssetSchemeTask,
        failure: PreviewAssetReadFailure,
        capture: AssetReadCapture,
        taskID: ObjectIdentifier
    ) {
        failCurrentSync(task, failure: failure, capture: capture, taskID: taskID)
    }

    @MainActor
    private func failCurrentSync(
        _ task: any PreviewAssetSchemeTask,
        failure: PreviewAssetReadFailure,
        capture: AssetReadCapture,
        taskID: ObjectIdentifier
    ) {
        guard state.permission(for: capture, taskID: taskID).acceptsDelivery else { return }
        task.fail(failure.schemeError)
        onCurrentFailure?(failure)
    }

    private func failMapped(
        _ task: any PreviewAssetSchemeTask,
        error: Error,
        capture: AssetReadCapture,
        taskID: ObjectIdentifier
    ) {
        let failure = PreviewAssetReadFailure.mapped(from: error)
        Task { @MainActor in
            self.failCurrentSync(task, failure: failure, capture: capture, taskID: taskID)
        }
    }

    private func report(_ failure: PreviewAssetReadFailure, capture: AssetReadCapture?, taskID: ObjectIdentifier) {
        Task { @MainActor in
            if let capture {
                guard self.state.permission(for: capture, taskID: taskID).acceptsDelivery else { return }
            }
            self.onCurrentFailure?(failure)
        }
    }
}

private extension PreviewAssetReadFailure {
    var schemeError: Error {
        switch self {
        case .unavailable, .accessChanged:
            CocoaError(.fileReadNoPermission)
        case .outsideRoot:
            CocoaError(.fileReadNoPermission)
        case .unsupportedType:
            CocoaError(.fileReadCorruptFile)
        case .tooLarge:
            CocoaError(.fileReadTooLarge)
        case .providerFailed:
            CocoaError(.fileReadUnknown)
        }
    }

    static func mapped(from error: Error) -> PreviewAssetReadFailure {
        switch error {
        case let failure as PreviewAssetReadFailure:
            failure
        case let policy as AssetURLPolicyError:
            switch policy {
            case .unsupportedType: .unsupportedType
            case .fileTooLarge: .tooLarge
            case .missingFileSize: .providerFailed
            }
        case is AssetURLResolverError:
            .outsideRoot
        default:
            .providerFailed
        }
    }
}

private final class SchemeTaskBox: @unchecked Sendable {
    let task: any PreviewAssetSchemeTask
    init(_ task: any PreviewAssetSchemeTask) {
        self.task = task
    }
}

private final class WKAssetSchemeTask: PreviewAssetSchemeTask {
    private let task: any WKURLSchemeTask
    var requestURL: URL? {
        task.request.url
    }

    init(_ task: any WKURLSchemeTask) {
        self.task = task
    }

    func receive(response: URLResponse) {
        task.didReceive(response)
    }

    func receive(data: Data) {
        task.didReceive(data)
    }

    func finish() {
        task.didFinish()
    }

    func fail(_ error: Error) {
        task.didFailWithError(error)
    }
}

private final class AssetReaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: (any PreviewAssetReading)?
    func set(_ reader: (any PreviewAssetReading)?) {
        lock.lock()
        self.reader = reader
        lock.unlock()
    }

    func current() -> (any PreviewAssetReading)? {
        lock.lock()
        defer { lock.unlock() }
        return reader
    }
}
