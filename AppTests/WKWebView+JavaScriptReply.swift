import WebKit

extension WKWebView {
    @MainActor
    @discardableResult
    func evaluateJavaScriptReply(_ script: String) async throws -> Any? {
        let reply = JavaScriptReply()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    reply.value = value
                    continuation.resume()
                }
            }
        }
        return reply.value
    }
}

@MainActor
private final class JavaScriptReply {
    var value: Any?
}
