import XCTest

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
