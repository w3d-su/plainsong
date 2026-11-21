import XCTest

@MainActor
func assertFulfillment(
    of expectations: [XCTestExpectation],
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let result = await XCTWaiter.fulfillment(of: expectations, timeout: timeout)
    XCTAssertEqual(
        result, .completed, "Waiting for \(expectations.map(\.expectationDescription)) returned \(result)",
        file: file, line: line
    )
}

@MainActor
func waitUntil(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: @MainActor () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await body() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("condition was not reached", file: file, line: line)
}
