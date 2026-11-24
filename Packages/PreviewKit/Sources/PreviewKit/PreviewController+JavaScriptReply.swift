import WebKit

extension PreviewController {
    /// Uses the completion-handler API, not the async import of `evaluateJavaScript(_:)`.
    /// Swift emits that import's bridging thunk in every module that awaits it, under one
    /// shared symbol. With Xcode 16.4, a Swift 6 module and a Swift 5 module in the same
    /// binary disagreed about the thunk, and the linker kept only one: awaiting it from the
    /// other module crashed with SIGSEGV (PreviewKitTests, PR 302 CI).
    func evaluateJavaScriptReply(_ script: String) async throws -> Any? {
        let reply = ExportJavaScriptReply()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(script, completionHandler: { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    reply.value = result
                    continuation.resume()
                }
            })
        }
        return reply.value
    }
}

/// Keeps WebKit's non-Sendable reply on the main actor; the continuation only signals completion.
@MainActor
private final class ExportJavaScriptReply {
    var value: Any?
}
