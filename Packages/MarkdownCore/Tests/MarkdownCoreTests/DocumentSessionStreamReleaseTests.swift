@testable import MarkdownCore
import XCTest

/// Codebase review, Medium: a released session ends its text-change streams.
final class DocumentSessionStreamReleaseTests: XCTestCase {
    @MainActor
    func testTextChangeStreamFinishesWhenTheSessionIsReleased() async {
        var session: DocumentSession? = DocumentSession(text: "a")
        let stream = session.map { $0.textChanges(includeCurrent: false) }
        let finished = expectation(description: "stream finished")
        let consumer = Task {
            guard let stream else { return }
            for await _ in stream {}
            finished.fulfill()
        }

        session = nil
        await fulfillment(of: [finished], timeout: 2)
        consumer.cancel()
    }
}
