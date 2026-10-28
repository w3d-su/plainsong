import Foundation
import MarkdownCore
@preconcurrency import WebKit

enum AssetURLPolicyError: Error, Equatable {
    case unsupportedType(String)
    case missingFileSize
    case fileTooLarge(actualBytes: Int64, maxBytes: Int64)
    /// Keeps the validator's reason in process; the scheme failure is still `unsupportedType`.
    case rejectedSVG(SVGImageRejection)
    /// The reader's coordinated file and the requested file disagree on being SVG, so the
    /// byte cap and the validator decision would have come from different files.
    case kindChangedDuringRead
}

struct AssetURLPolicyResult: Equatable {
    let mimeType: String
    let data: Data
    /// Set only for an admitted SVG. Raster responses stay header-less.
    let contentSecurityPolicy: String?

    init(mimeType: String, data: Data, contentSecurityPolicy: String? = nil) {
        self.mimeType = mimeType
        self.data = data
        self.contentSecurityPolicy = contentSecurityPolicy
    }
}

enum AssetURLPolicy {
    static let maxAssetBytes = MarkdownImageAssetPolicy.maximumFileSizeBytes

    static func isSVG(_ fileURL: URL) -> Bool {
        fileURL.pathExtension.lowercased() == "svg"
    }

    /// Raster files keep the 10 MiB cap. SVG is capped before it is parsed.
    static func maximumPreviewByteCount(for fileURL: URL) -> Int64 {
        if isSVG(fileURL) {
            return Int64(SVGImageValidator.maximumByteCount)
        }
        return maxAssetBytes
    }

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
        let reader = readers.current()
        let box = SchemeTaskBox(task)
        let readTask = Task.detached { [weak self] in
            let resolved: URL
            do {
                resolved = try AssetFilesystemPreparation.resolvedAssetURL(
                    requestURL,
                    allowedRoot: capture.allowedRoot
                )
            } catch {
                await self?.failMapped(box.task, error: error, capture: capture, taskID: taskID)
                return
            }
            guard let self else { return }
            guard await acceptsDelivery(capture, taskID: taskID) else { return }
            let request = PreviewAssetReadRequest(
                requestID: capture.requestID,
                resolvedURL: resolved,
                access: capture.access,
                maximumByteCount: Int(exactly: AssetURLPolicy.maximumPreviewByteCount(for: resolved)) ?? .max
            )
            do {
                try Task.checkCancellation()
                guard let reader else {
                    await failCurrent(box.task, failure: .unavailable, capture: capture, taskID: taskID)
                    return
                }
                let result = try await reader.read(request)
                try Task.checkCancellation()
                guard let root = await deliveryRoot(
                    box.task,
                    result: result,
                    capture: capture,
                    taskID: taskID
                ) else { return }
                let prepared = try AssetFilesystemPreparation.containedAsset(
                    result.bytes,
                    fileURL: result.coordinatedURL,
                    requestedURL: resolved,
                    root: root
                )
                try Task.checkCancellation()
                await deliverPrepared(
                    box.task,
                    asset: prepared.asset,
                    displayURL: prepared.fileURL,
                    capture: capture,
                    taskID: taskID
                )
            } catch is CancellationError {
                return
            } catch {
                await failMapped(box.task, error: error, capture: capture, taskID: taskID)
            }
        }
        state.store(readTask, id: taskID)
    }

    @MainActor
    private func acceptsDelivery(_ capture: AssetReadCapture, taskID: ObjectIdentifier) -> Bool {
        state.permission(for: capture, taskID: taskID).acceptsDelivery
    }

    /// Permission and generation are read on the main thread. The caller resolves
    /// the returned root off the main thread, then delivers only after another check.
    @MainActor
    private func deliveryRoot(
        _ task: any PreviewAssetSchemeTask,
        result: PreviewAssetReadResult,
        capture: AssetReadCapture,
        taskID: ObjectIdentifier
    ) -> URL? {
        let permission = state.permission(for: capture, taskID: taskID)
        guard permission.acceptsDelivery, let root = permission.allowedRoot else { return nil }
        guard result.requestID == capture.requestID, AssetAuthority.matches(result.access, capture.access) else {
            failCurrentSync(task, failure: .accessChanged, capture: capture, taskID: taskID)
            return nil
        }
        return root
    }

    @MainActor
    private func deliverPrepared(
        _ task: any PreviewAssetSchemeTask,
        asset: AssetURLPolicyResult,
        displayURL: URL,
        capture: AssetReadCapture,
        taskID: ObjectIdentifier
    ) {
        guard state.permission(for: capture, taskID: taskID).acceptsDelivery else { return }
        guard let response = AssetDeliveryResponse.make(
            url: task.requestURL ?? displayURL,
            asset: asset
        ) else {
            // An SVG never goes out without its headers.
            failCurrentSync(task, failure: .providerFailed, capture: capture, taskID: taskID)
            return
        }
        task.receive(response: response)
        guard state.permission(for: capture, taskID: taskID).acceptsDelivery else { return }
        task.receive(data: asset.data)
        guard state.permission(for: capture, taskID: taskID).acceptsDelivery else { return }
        task.finish()
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
            case .unsupportedType, .rejectedSVG, .kindChangedDuringRead: .unsupportedType
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
