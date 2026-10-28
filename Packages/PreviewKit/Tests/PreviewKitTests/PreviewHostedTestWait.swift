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

    /// Targeted phase markers and failures only; never print each poll or script/source text.
    static func note(_ operation: String, phase: String) {
        print("PREVIEW_TEST_DIAGNOSTIC t=\(DispatchTime.now().uptimeNanoseconds) " +
            "operation=\(String(reflecting: operation)) phase=\(phase)")
    }

    private static func note(_ operation: String, phase: String, error: Error) {
        let bridged = error as NSError
        print("PREVIEW_TEST_DIAGNOSTIC t=\(DispatchTime.now().uptimeNanoseconds) " +
            "operation=\(String(reflecting: operation)) phase=\(phase) " +
            "errorType=\(String(reflecting: type(of: error))) " +
            "domain=\(String(reflecting: bridged.domain)) code=\(bridged.code) " +
            "cancelled=\(Task.isCancelled) description=\(String(reflecting: String(describing: error)))")
    }

    static func until(
        _ description: String,
        timeoutNanoseconds: UInt64 = 8_000_000_000,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            do { try Task.checkCancellation() } catch {
                note(description, phase: "check-cancellation-error", error: error)
                throw error
            }
            do {
                if try await condition() {
                    return
                }
            } catch {
                note(description, phase: "condition-error", error: error)
                throw error
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch {
                note(description, phase: "poll-sleep-error", error: error)
                throw error
            }
        }
        let failure = Failure.timedOut(description)
        note(description, phase: "own-timeout-before-throw", error: failure)
        throw failure
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
        do { try Task.checkCancellation() } catch {
            note(description, phase: "callback-check-cancellation-error", error: error)
            throw error
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = CompletionGate(continuation, operation: description)
            gate.deadline = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch {
                    if !(error is CancellationError) {
                        note(description, phase: "callback-deadline-sleep-error", error: error)
                    }
                    return
                }
                gate.finish(.failure(Failure.timedOut(description)), phase: "callback-deadline-error")
            }
            operation { result in gate.finish(result, phase: "callback-delivered-error") }
        }
    }

    @MainActor
    private final class CompletionGate {
        private var continuation: CheckedContinuation<Any?, Error>?
        private let operation: String
        var deadline: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Any?, Error>, operation: String) {
            self.continuation = continuation
            self.operation = operation
        }

        func finish(_ result: Result<Any?, Error>, phase: String) {
            guard let pending = continuation else { return }
            continuation = nil
            deadline?.cancel()
            deadline = nil
            if case let .failure(error) = result {
                PreviewHostedTestWait.note(operation, phase: phase, error: error)
            }
            pending.resume(with: result)
        }
    }
}
