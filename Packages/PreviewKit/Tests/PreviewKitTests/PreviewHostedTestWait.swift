import Foundation
import WebKit

/// Test-only deadlines must not wait for a nonresponsive WebContent task to drain.
/// The callback gate also ignores WebKit replies that arrive after the deadline.
@MainActor
enum PreviewHostedTestWait {
    enum Failure: Error, CustomStringConvertible {
        case timedOut(String)

        var description: String {
            switch self {
            case let .timedOut(operation): "Timed out waiting for \(operation)"
            }
        }
    }

    static func until(
        _ description: String,
        timeoutNanoseconds: UInt64 = 8_000_000_000,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try Task.checkCancellation()
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.timedOut(description)
    }

    static func javascript(
        _ script: String,
        in webView: WKWebView,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws -> Any? {
        try await callback("JavaScript reply", timeoutNanoseconds: timeoutNanoseconds) { complete in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    complete(.failure(error))
                } else {
                    complete(.success(value))
                }
            }
        }
    }

    static func callback(
        _ description: String,
        timeoutNanoseconds: UInt64,
        operation: (@escaping @MainActor @Sendable (Result<Any?, Error>) -> Void) -> Void
    ) async throws -> Any? {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let gate = CompletionGate(continuation)
            gate.deadline = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                gate.finish(.failure(Failure.timedOut(description)))
            }
            operation { result in gate.finish(result) }
        }
    }

    private final class CompletionGate {
        private var continuation: CheckedContinuation<Any?, Error>?
        var deadline: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Any?, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<Any?, Error>) {
            guard let pending = continuation else { return }
            continuation = nil
            deadline?.cancel()
            deadline = nil
            pending.resume(with: result)
        }
    }
}
