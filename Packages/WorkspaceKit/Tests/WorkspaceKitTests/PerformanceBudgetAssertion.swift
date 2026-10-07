import Foundation
import XCTest

/// R15 wall-clock budget assertion: hard failure locally, informational print on CI hosts,
/// where shared-runner scheduling variance makes wall-clock budgets unreliable.
extension XCTestCase {
    static var isContinuousIntegration: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] != nil || environment["GITHUB_ACTIONS"] != nil
    }

    func assertPerformanceBudget(
        _ value: Double,
        lessThanOrEqualTo budget: Double,
        metric: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard value > budget else {
            return
        }

        let message = String(
            format: "PERF %@ %.3f ms exceeded %.3f ms budget",
            metric,
            value,
            budget
        )
        if Self.isContinuousIntegration {
            print("\(message) on CI; recorded as informational per risk R15")
            return
        }

        XCTFail(message, file: file, line: line)
    }
}
