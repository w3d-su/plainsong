import Foundation
import XCTest

@MainActor
final class PreviewHostedDeadlineTests: XCTestCase {
    func testFalseConditionThrowsInsteadOfContinuingTheTest() async throws {
        var continued = false
        do {
            try await PreviewHostedTestWait.until("never ready", timeoutNanoseconds: 1_000_000) { false }
            continued = true
        } catch let error as PreviewHostedTestWait.Failure {
            XCTAssertEqual(error.description, "Timed out waiting for never ready")
        }
        XCTAssertFalse(continued)
    }

    func testMissingJavaScriptReplyTimesOutAndLateReplyCannotResumeTwice() async throws {
        var reply: (@MainActor @Sendable (Result<Any?, Error>) -> Void)?
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await PreviewHostedTestWait.callback("missing reply", timeoutNanoseconds: 10_000_000) {
                reply = $0
            }
            XCTFail("A missing callback must throw")
        } catch let error as PreviewHostedTestWait.Failure {
            XCTAssertEqual(error.description, "Timed out waiting for missing reply")
        }
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 2_000_000_000)
        reply?(.success("late"))
        reply?(.failure(PreviewHostedTestWait.Failure.timedOut("duplicate")))
    }

    func testCompletedJavaScriptReplyIgnoresDuplicateAndCancelsDeadline() async throws {
        let result = try await PreviewHostedTestWait.callback("immediate reply", timeoutNanoseconds: 10_000_000) {
            $0(.success("first"))
            $0(.success("duplicate"))
        }
        XCTAssertEqual(result as? String, "first")
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
