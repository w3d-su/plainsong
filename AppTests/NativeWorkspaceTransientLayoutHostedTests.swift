import AppKit
@testable import Plainsong
import XCTest

/// Handoff 29b MEDIUM 1: the first layout pass after a mode switch or a shrinking resize
/// must not draw overlapping panes. The inspector's visibility publish is deferred one
/// turn, so the frames below are sampled synchronously — before the test yields to the
/// main actor and lets the deferred apply run.
@MainActor
extension EditorFindHostedGateTests {
    func testTransientSourceToSplitDoesNotOverlapOnFixedShell() async throws {
        try await checkTransientModeSwitch(shell: .fixed, width: 864)
    }

    func testTransientSourceToSplitDoesNotOverlapOnSplitShell() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Split shell is gated to macOS 27+") }
        try await checkTransientModeSwitch(shell: .split, width: 900)
    }

    func testTransientShrinkDoesNotOverlapOnFixedShell() async throws {
        try await checkTransientShrink(shell: .fixed, width: 864)
    }

    func testTransientShrinkDoesNotOverlapOnSplitShell() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Split shell is gated to macOS 27+") }
        try await checkTransientShrink(shell: .split, width: 900)
    }

    /// Source-only at `width`, inspector settled and visible, then a same-pass switch to Split.
    ///
    /// macOS 27 applies the published mode switch inside the synchronous layout, so there the
    /// first sample must already be Split; that is what makes the same-pass negative control
    /// fail. Earlier SwiftUI applies an `ObservableObject` change only on a later run-loop turn
    /// (the macOS 15 CI runner sampled the untouched Source layout), so before macOS 27 an
    /// unrendered sample must equal the pre-switch frames, and the first sample that renders
    /// Split is checked instead, one main-queue hop at a time.
    private func checkTransientModeSwitch(shell: WorkspaceShell, width: CGFloat) async throws {
        let settled = try await makeSettledInspectorHost(shell: shell, width: width, mode: .sourceOnly)
        let label = "mode-switch shell=\(shell) width=\(width)"
        let before = transientFrames(in: settled.host)
        settled.state.setLayoutMode(.sourcePreview)
        var frames = transientFrames(in: settled.host)
        var branch = "same-pass"
        // macOS 27+ gets no fallback: the synchronous sample has to contain the preview.
        if #unavailable(macOS 27.0), frames["preview"] == nil {
            var turns = 0
            while frames["preview"] == nil, turns < 50 {
                XCTAssertTrue(
                    framesMatch(frames, before),
                    "\(label): unrendered sample after \(turns) turns differs from the pre-switch frames"
                        + " \(frames) vs \(before)"
                )
                await nextMainQueueTurn()
                turns += 1
                frames = transientFrames(in: settled.host)
            }
            branch = "deferred-render turns=\(turns)"
        }
        try assertNoTransientOverlap(frames, label: "\(label) branch=\(branch)")
        try await waitUntil("layout settles after mode switch") {
            settled.host.hostingView.layoutSubtreeIfNeeded()
            return self.layoutFrame("inspector", in: settled.host.window) == nil
        }
    }

    /// Split at 1280 with the inspector settled, then a same-pass shrink to `width`.
    private func checkTransientShrink(shell: WorkspaceShell, width: CGFloat) async throws {
        let settled = try await makeSettledInspectorHost(shell: shell, width: 1280, mode: .sourcePreview)
        settled.host.window.setContentSize(NSSize(width: width, height: 680))
        try assertNoTransientOverlap(
            transientFrames(in: settled.host),
            label: "shrink shell=\(shell) width=\(width)"
        )
        try await waitUntil("layout settles after shrink") {
            settled.host.hostingView.layoutSubtreeIfNeeded()
            return self.layoutFrame("inspector", in: settled.host.window) == nil
        }
    }

    /// Hosts the production window with inspector intent on and waits until the inspector
    /// is actually laid out at `width` in `mode`.
    private func makeSettledInspectorHost(
        shell: WorkspaceShell, width: CGFloat, mode: EditorLayoutMode
    ) async throws -> (host: HostedWorkspace, state: AppState) {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "# Layout\n"])
        let state = fixture.appState
        state.openExternalFile(fixture.root)
        try await waitUntil("transient fixture opens") { state.currentDocument.fileURL != nil }
        state.setLayoutMode(mode)
        let host = makeNativeLayoutHost(
            appState: state, shell: shell, setting: NativeInspectorIntent(true)
        )
        registerTeardown(host: host, fixture: fixture)
        host.window.setContentSize(NSSize(width: width, height: 680))
        try await waitUntil("inspector settled at \(width)") {
            host.hostingView.layoutSubtreeIfNeeded()
            return self.layoutFrame("inspector", in: host.window) != nil
        }
        return (host, state)
    }

    /// Forces the pending render and reads the probe frames without suspending.
    private func transientFrames(in host: HostedWorkspace) -> [String: NSRect] {
        host.hostingView.needsLayout = true
        host.hostingView.layoutSubtreeIfNeeded()
        host.window.displayIfNeeded()
        var frames: [String: NSRect] = [:]
        for name in ["sidebar", "editor", "preview", "handle", "inspector"] {
            if let frame = layoutFrame(name, in: host.window) {
                frames[name] = frame
            }
        }
        return frames
    }

    private func framesMatch(_ lhs: [String: NSRect], _ rhs: [String: NSRect]) -> Bool {
        lhs.keys.sorted() == rhs.keys.sorted() && lhs.allSatisfy { name, frame in
            guard let other = rhs[name] else { return false }
            return abs(frame.minX - other.minX) <= 0.5 && abs(frame.minY - other.minY) <= 0.5
                && abs(frame.width - other.width) <= 0.5 && abs(frame.height - other.height) <= 0.5
        }
    }

    /// One hop through the main queue, so the run loop gets a turn (and SwiftUI its pending
    /// update) between two samples without skipping several turns at once.
    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func assertNoTransientOverlap(_ frames: [String: NSRect], label: String) throws {
        let report = frames.keys.sorted().map { "\($0)=\(frames[$0]!)" }.joined(separator: " ")
        print("TRANSIENT \(label) \(report)")
        XCTAssertNotNil(frames["sidebar"], label)
        let editor = try XCTUnwrap(frames["editor"], "\(label): no editor probe")
        XCTAssertGreaterThanOrEqual(
            editor.width, WorkspaceLayout.editorMinimum - 0.5, "\(label): \(report)"
        )
        let preview = try XCTUnwrap(frames["preview"], "\(label): no preview probe")
        XCTAssertGreaterThanOrEqual(
            preview.width, WorkspaceLayout.previewMinimum - 0.5, "\(label): \(report)"
        )
        let laidOut = frames.keys.sorted().compactMap { frames[$0] }
        for left in laidOut.indices {
            for right in laidOut.indices where right > left {
                XCTAssertLessThanOrEqual(
                    laidOut[left].intersection(laidOut[right]).width, 0.5,
                    "\(label): \(report)"
                )
            }
        }
    }
}
