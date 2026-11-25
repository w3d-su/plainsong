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

    /// Tests evaluate JavaScript only through this completion-handler helper. Every module
    /// that awaits the async `WKWebView.evaluateJavaScript(_:)` import emits its bridging thunk
    /// under one shared symbol; with Xcode 16.4, Swift 6 tests and a Swift 5 PreviewKit
    /// disagreed about that thunk and the test process crashed with SIGSEGV (PR 298 CI).
    static func javascript(
        _ script: String,
        in webView: WKWebView,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws -> Any? {
        try await callback("JavaScript reply", timeoutNanoseconds: timeoutNanoseconds) { complete in
            webView.evaluateJavaScript(script, completionHandler: { value, error in
                if let error {
                    complete(.failure(error))
                } else {
                    complete(.success(value))
                }
            })
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
        // Keep WebKit's non-Sendable reply on the main actor; the continuation only signals completion.
        let gate = CompletionGate(operation: description)
        try await withCheckedThrowingContinuation { continuation in
            gate.continuation = continuation
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
        return gate.value
    }

    @MainActor
    private final class CompletionGate {
        private let operation: String
        var continuation: CheckedContinuation<Void, Error>?
        private(set) var value: Any?
        var deadline: Task<Void, Never>?

        init(operation: String) {
            self.operation = operation
        }

        func finish(_ result: Result<Any?, Error>, phase: String) {
            guard let pending = continuation else { return }
            continuation = nil
            deadline?.cancel()
            deadline = nil
            switch result {
            case let .success(value):
                self.value = value
                pending.resume()
            case let .failure(error):
                PreviewHostedTestWait.note(operation, phase: phase, error: error)
                pending.resume(throwing: error)
            }
        }
    }
}
