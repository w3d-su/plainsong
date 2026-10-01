import AppKit
@testable import EditorKit
@testable import Plainsong
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    /// Opt-in local typing gate (docs/perf-log.md, Replace PR F). Its first-iteration
    /// maximum can exceed 16 ms in both the #131 baseline and PR F on a busy machine, so
    /// a plain `make test` skips it rather than flaking; the budget itself is unchanged.
    func testHostedLargeFixtureWYSIWYGTypingWithReplaceFindSessionStaysUnderBudget() async throws {
        try Self.requireHostedTypingGateOptIn()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Fixtures/large-1mb.md"))
        let hosted = try await makeHostedReplaceWorkspace(source: source, query: "ordinary prose", layoutMode: .wysiwyg)
        try await waitUntil("production WYSIWYG and its initial styling are installed") {
            guard let editor = self.editorTextView(in: hosted.window),
                  let coordinator = editor.textDelegate as? MarkdownTextViewCoordinator else { return false }
            return editor.wysiwygZeroWidthContentStorageDelegate != nil
                && coordinator.lastAppliedHighlightRevision != nil
                && hosted.appState.editorReplaceAuthorizationDecision(for: hosted.appState.currentDocument) == .allowed
        }
        // Functional hosted helpers remove Find's debounce to make navigation deterministic.
        // Restore the real default before measuring the production typing path.
        let controller = hosted.appState.editorFindHost.controller
        controller.debounceNanoseconds = EditorFindController(documentBinding: controller.documentBinding)
            .debounceNanoseconds
        let editor = try hostedEditor(hosted)
        editor.textSelection = NSRange(location: 0, length: 0)
        var samples: [Double] = []
        for _ in 0 ..< 30 {
            let revision = hosted.appState.currentDocument.version
            let start = DispatchTime.now().uptimeNanoseconds
            editor.insertText("a", replacementRange: editor.selectedRange())
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(hosted.appState.currentDocument.version, revision + 1)
            // Let the real SwiftUI debounce, selection reveal and Find recompute run
            // between inputs, while only the synchronous native input is timed.
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let maximum = try XCTUnwrap(samples.max())
        let attachment = XCTAttachment(string: "samples milliseconds: \(samples); maximum: \(maximum)")
        attachment.name = "Replace WYSIWYG native typing"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("Hosted Replace WYSIWYG large-1mb.md typing milliseconds: \(samples)")
        let environment = ProcessInfo.processInfo.environment
        let isCI = environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"
        print("Hosted Replace WYSIWYG budget mode: \(isCI ? "ci-informational" : "local-hard"); maximum: \(maximum)")
        if !isCI {
            XCTAssertLessThan(maximum, 16, "native input including production debounce scheduling: \(samples)")
        }
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.string, hosted.appState.currentDocument.text)
    }

    private static let hostedTypingGateOptIn = "PLAINSONG_RUN_HOSTED_TYPING_GATE"

    private static func requireHostedTypingGateOptIn() throws {
        guard ProcessInfo.processInfo.environment[hostedTypingGateOptIn] == "1" else {
            throw XCTSkip("""
            Hosted large-1mb.md WYSIWYG typing gate is opt-in. Rerun with \
            TEST_RUNNER_\(hostedTypingGateOptIn)=1 on an idle machine; see docs/perf-log.md.
            """)
        }
    }
}
