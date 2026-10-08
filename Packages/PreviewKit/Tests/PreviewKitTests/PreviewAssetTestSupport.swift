import Foundation
@testable import PreviewKit
import XCTest

enum PreviewAssetTestSupport {
    static let onePixelPNG = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAFgwJ/lD3G7wAAAABJRU5ErkJggg==
    """)!

    static func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func access(
        root: URL,
        generation: UInt64,
        grant: UUID = UUID(),
        token: UUID = UUID()
    ) -> PreviewAssetAccessContext {
        PreviewAssetAccessContext(
            allowedRoot: root,
            rootToken: token,
            grantIdentity: grant,
            accessGeneration: generation
        )
    }

    static func assetURL(token: String, path: String = "pixel.png") -> URL {
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return URL(string: "asset://\(path)?plainsong-root=\(encoded)")!
    }

    static func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

final class GatePreviewAssetReader: PreviewAssetReading, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(PreviewAssetReadRequest, CheckedContinuation<PreviewAssetReadResult, Error>)] = []
    private var readCountStorage = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCountStorage
    }

    func read(_ request: PreviewAssetReadRequest) async throws -> PreviewAssetReadResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readCountStorage += 1
            waiters.append((request, continuation))
            lock.unlock()
        }
    }

    func hasWaiter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !waiters.isEmpty
    }

    func resumeFirst(bytes: Data, coordinatedURL: URL? = nil) {
        lock.lock()
        let waiter = waiters.removeFirst()
        lock.unlock()
        waiter.1.resume(returning: PreviewAssetReadResult(
            requestID: waiter.0.requestID,
            coordinatedURL: coordinatedURL ?? waiter.0.resolvedURL,
            bytes: bytes,
            access: waiter.0.access
        ))
    }
}

final class RecordingSchemeTask: PreviewAssetSchemeTask {
    let requestURL: URL?
    private(set) var data = Data()
    private(set) var responseCount = 0
    private(set) var finished = 0
    private(set) var failures = 0
    var onTerminal: (() -> Void)?

    init(url: URL?) {
        requestURL = url
    }

    func receive(response _: URLResponse) {
        responseCount += 1
    }

    func receive(data: Data) {
        self.data.append(data)
    }

    func finish() {
        finished += 1
        onTerminal?()
    }

    func fail(_: Error) {
        failures += 1
        onTerminal?()
    }
}
