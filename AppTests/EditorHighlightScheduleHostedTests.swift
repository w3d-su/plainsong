import AppKit
@testable import EditorKit
@testable import Plainsong
import XCTest

/// Opt-in hosted probes for the editor highlight scheduler (Decision Log 2026-10-01).
/// Neither runs in a plain `make test`: both depend on wall-clock behavior of a shared Mac.
@MainActor
extension EditorFindHostedGateTests {
    /// Stress reproduction of the dropped final highlight request. Each native edit, Undo or
    /// Redo bumps the highlight revision several times in quick succession (binding, text,
    /// selection, viewport). Under SwiftUI `.task(id:)` the final request was sometimes
    /// never started, so no highlight applied after the edit. Run it on two trees and
    /// compare the reported drop counts; this branch must report none.
    func testHostedHighlightScheduleStressAppliesAfterEveryEdit() async throws {
        try Self.requireHostedOptIn("PLAINSONG_RUN_HIGHLIGHT_SCHEDULE_STRESS", purpose: "highlight-schedule stress")
        let source = "Intro **文字😀** tail"
        let hosted = try await makeHostedEditorWorkspace(source: source, layoutMode: .wysiwyg)
        let editor = try hostedEditor(hosted)
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        let edited = "Intro **新🦊** tail"
        let range = (source as NSString).range(of: "文字😀")
        var drops: [String] = []
        let cycles = 15
        for cycle in 0 ..< cycles {
            for step in ["edit", "undo", "redo", "undo"] {
                await settleHighlight(coordinator)
                let before = coordinator.lastAppliedHighlightRevision
                switch step {
                case "edit":
                    editor.breakUndoCoalescing()
                    editor.insertText("新🦊", replacementRange: range)
                case "undo":
                    editor.undoManager?.undo()
                default:
                    editor.undoManager?.redo()
                }
                XCTAssertEqual(hosted.appState.currentDocument.text, step == "undo" ? source : edited)
                let applied = await poll(timeout: 3) { coordinator.lastAppliedHighlightRevision != before }
                await settleHighlight(coordinator)
                let plan = try XCTUnwrap(coordinator.lastAppliedHighlightFoldPlan)
                let expected = try MarkdownSyntaxParser().visibleTokensAndFoldPlan(
                    in: hosted.appState.currentDocument.text, fileKind: .markdown,
                    visibleRange: plan.visibleRange, selection: editor.selectedRange(),
                    linkFoldingEnabled: plan.linkFoldingEnabled
                ).foldPlan
                XCTAssertEqual(plan, expected, "settled fold plan must reflect current text and selection")
                if !applied {
                    drops.append("\(cycle):\(step)")
                }
            }
        }
        let report = "highlight-schedule stress: \(drops.count) drops in \(cycles * 4) edits; dropped: \(drops)"
        let attachment = XCTAttachment(string: report)
        attachment.name = "Highlight schedule stress"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(report)
        XCTAssertEqual(drops, [], "every edit must end in an applied highlight")
    }

    /// Opt-in local typing probe, the method of
    /// `docs/evidence/editor-highlight-schedule-20261001-typing.json`, with an open Find
    /// session and its production 150 ms debounce.
    func testHostedLargeFixtureWYSIWYGTypingStaysUnderBudget() async throws {
        try await assertHostedLargeFixtureTyping(layoutMode: .wysiwyg)
    }

    func testHostedLargeFixtureSourceOnlyTypingStaysUnderBudget() async throws {
        try await assertHostedLargeFixtureTyping(layoutMode: .sourceOnly)
    }

    func makeHostedEditorWorkspace(source: String,
                                   layoutMode: EditorLayoutMode) async throws -> HostedReplaceWorkspace
    {
        let fixture = try makeWorkspaceFixture(files: ["post.md": source])
        let appState = fixture.appState
        if layoutMode == .wysiwyg {
            appState.preferences.setExperimentalWYSIWYGEnabled(true)
        }
        appState.setLayoutMode(layoutMode)
        appState.preferences.setAutosaveIntervalSeconds(30)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
        }
        let group = makeHostedWorkspaceGroup(fixture: fixture)
        let window = mountDesignatedKeyWorkspace(in: group, appState: appState)
        designateKeyWindow(window, in: group)
        let hosted = HostedReplaceWorkspace(fixture: fixture, group: group, window: window)
        try await waitUntil("editor installs and applies its initial styling", timeout: 20) {
            guard let editor = self.editorTextView(in: window),
                  let coordinator = editor.textDelegate as? MarkdownTextViewCoordinator
            else { return false }
            return coordinator.lastAppliedHighlightRevision != nil
                && (layoutMode != .wysiwyg || editor.wysiwygZeroWidthContentStorageDelegate != nil)
        }
        let editor = try hostedEditor(hosted)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.undoManager?.removeAllActions()
        return hosted
    }

    private func assertHostedLargeFixtureTyping(layoutMode: EditorLayoutMode) async throws {
        try Self.requireHostedOptIn("PLAINSONG_RUN_HOSTED_TYPING_GATE", purpose: "hosted large-1mb.md typing gate")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "large-1mb", withExtension: "md"))
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let hosted = try await makeHostedEditorWorkspace(source: source, layoutMode: layoutMode)
        designateReplaceKeyWindow(in: hosted.group)
        openFindBar(hosted.appState, query: "ordinary prose")
        try await focusEditorOnCurrentMatch(hosted, window: hosted.window)
        try await waitUntil("initial styling and Replace authority are ready") {
            hosted.appState.editorReplaceAuthorizationDecision(for: hosted.appState.currentDocument) == .allowed
        }
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
            // Let the real debounce, selection reveal and parse run between inputs, while
            // only the synchronous native input is timed.
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let maximum = try XCTUnwrap(samples.max())
        let mode = layoutMode == .wysiwyg ? "wysiwyg" : "source-only"
        let report = "Hosted \(mode) large-1mb.md typing milliseconds: \(samples); maximum: \(maximum)"
        let attachment = XCTAttachment(string: report)
        attachment.name = "Hosted \(mode) native typing"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(report)
        let environment = ProcessInfo.processInfo.environment
        if environment["CI"] != "true", environment["GITHUB_ACTIONS"] != "true" {
            XCTAssertLessThan(maximum, 16, "native input including debounce scheduling: \(samples)")
        }
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.string, hosted.appState.currentDocument.text)
    }

    /// Waits until no highlight has applied for 150 ms, so the next edit starts from rest.
    private func settleHighlight(_ coordinator: MarkdownTextViewCoordinator) async {
        let deadline = Date().addingTimeInterval(2)
        var last = coordinator.lastAppliedHighlightRevision
        var quietSince = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if coordinator.lastAppliedHighlightRevision != last {
                last = coordinator.lastAppliedHighlightRevision
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= 0.15 {
                return
            }
        }
    }

    private func poll(timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    private static func requireHostedOptIn(_ variable: String, purpose: String) throws {
        guard ProcessInfo.processInfo.environment[variable] == "1" else {
            throw XCTSkip("The \(purpose) is opt-in. Rerun with TEST_RUNNER_\(variable)=1; see docs/perf-log.md.")
        }
    }
}
