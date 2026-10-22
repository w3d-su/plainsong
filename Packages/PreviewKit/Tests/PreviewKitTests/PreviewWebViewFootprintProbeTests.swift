#if os(macOS)
    import Foundation
    @testable import PreviewKit
    import XCTest

    /// What one idle live preview costs in WebKit helper processes: the page loaded and ready,
    /// no document rendered, which is what a source-only workspace window paid before it
    /// stopped creating its `PreviewController`
    /// (`docs/perf/2026-10-22-preview-webview-lifecycle.md`). Opt-in, one fresh process per run:
    /// `PLAINSONG_RUN_PREVIEW_FOOTPRINT_PROBE=1 swift test --filter PreviewWebViewFootprintProbeTests`.
    @MainActor
    final class PreviewWebViewFootprintProbeTests: XCTestCase {
        func testIdleLivePreviewHelperFootprint() async throws {
            guard ProcessInfo.processInfo.environment["PLAINSONG_RUN_PREVIEW_FOOTPRINT_PROBE"] == "1" else {
                throw XCTSkip("Helper footprint diagnostics are opt-in: PLAINSONG_RUN_PREVIEW_FOOTPRINT_PROBE=1")
            }
            let before = try webKitHelpers()
            let controller = try PreviewController(previewIndexURL: PreviewBundleFixture.indexURL())
            defer { controller.shutdownForTesting() }
            try await PreviewHostedTestWait.until("bundle ready", timeoutNanoseconds: 30_000_000_000) {
                controller.isReady
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let after = try webKitHelpers()
            let started = after.filter { before[$0.key] == nil }
            let rssMB = Double(started.values.map(\.rssKB).reduce(0, +)) / 1024
            let names = started.values.map(\.name).sorted().joined(separator: ",")
            print(String(
                format: "PREVIEW_FOOTPRINT_PROBE new_helpers=%d new_helper_rss_mb=%.1f names=%@",
                started.count,
                rssMB,
                names
            ))
        }

        private struct Helper {
            let rssKB: Int
            let name: String
        }

        private func webKitHelpers() throws -> [Int32: Helper] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,rss=,comm="]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var helpers: [Int32: Helper] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard fields.count == 3, let pid = Int32(fields[0]), let rss = Int(fields[1]),
                      fields[2].contains("com.apple.WebKit")
                else { continue }
                helpers[pid] = Helper(rssKB: rss, name: String(fields[2].split(separator: "/").last ?? ""))
            }
            return helpers
        }
    }
#endif
