import EditorKitIOS
import Foundation
import MarkdownCore
import SyntaxKit
import XCTest

/// Simulator instrumentation only. Device p95 typing and visible-highlight budgets stay open.
final class IOSHighlightPerformanceDiagnosticTests: XCTestCase {
    func testFixtureScansRunOffMain() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for name in ["perf-100kb.md", "large-1mb.md"] {
            let url = root.appendingPathComponent("Fixtures/\(name)")
            let text = try String(contentsOf: url, encoding: .utf8)
            let probe = IOSScanProbe()
            let request = SyntaxRequest(
                requestID: UUID(),
                version: 1,
                source: text,
                fileKind: .markdown,
                visibleRange: NSRange(location: 0, length: min(256, (text as NSString).length))
            )
            let clock = ContinuousClock()
            let started = clock.now
            let task = Task { try await probe.tokens(for: request) }
            let scheduled = clock.now - started
            _ = try await task.value
            XCTAssertTrue(probe.ranOffMain, name)
            let scheduleNs = scheduled.components.seconds * 1_000_000_000
                + scheduled.components.attoseconds / 1_000_000_000
            print(
                "LANE04 fixture=\(name) utf8=\(text.utf8.count) " +
                    "scanNs=\(probe.elapsedNanoseconds) scheduleNs=\(scheduleNs)"
            )
        }
    }
}
