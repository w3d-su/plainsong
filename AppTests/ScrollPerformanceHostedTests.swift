import AppKit
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
@testable import PreviewKit
import XCTest

/// Run on the same Mac/tree pair with TEST_RUNNER_PLAINSONG_RUN_SCROLL_PROBE=1.
/// Loaded-machine timings are diagnostics, not idle-machine performance acceptance.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedViewportReuseStillRefreshesAfterEditingAndUndo() async throws {
        let source = String(repeating: "Paragraph **bold** with 中文😀.\n\n", count: 200)
        let hosted = try await makeHostedEditorWorkspace(source: source)
        let editor = try hostedEditor(hosted)
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        // Let the initial attributed layout finish reporting its viewport.
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = coordinator.lastAppliedHighlightRevision
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 24))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(coordinator.lastAppliedHighlightRevision, before,
                       "A small scroll inside the highlighted window must reuse its attributes")
        editor.textSelection = NSRange(location: 10, length: 0)
        editor.insertText("new", replacementRange: editor.selectedRange())
        try await waitUntil("edit refreshes a cached highlight viewport") {
            coordinator.lastAppliedHighlightRevision != before
        }
        let afterEdit = coordinator.lastAppliedHighlightRevision
        editor.undoManager?.undo()
        try await waitUntil("Undo refreshes the highlight viewport") {
            coordinator.lastAppliedHighlightRevision != afterEdit
                && hosted.appState.currentDocument.text == source
        }
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.string, source)
    }

    func testHostedEditorScrollWorkload() async throws {
        try requireScrollProbe()
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "large-1mb", withExtension: "md"))
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let hosted = try await makeHostedEditorWorkspace(source: source)
        let editor = try hostedEditor(hosted)
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        let selection = editor.selectedRange()
        var samples: [Double] = []
        var appliedRevisions: Set<Int> = []
        // Use real clip-view scrolling and allow the production debounce/layout to run.
        // Move both ways through the same region, then repeat near the document tail.
        for anchor in [0, source.utf16.count * 4 / 5] {
            editor.scrollRangeToVisible(NSRange(location: anchor, length: 0))
            try await Task.sleep(nanoseconds: 300_000_000)
            let origin = scrollView.contentView.bounds.origin.y
            for step in 0 ..< 80 {
                let distance = CGFloat(step < 40 ? step : 79 - step) * 12
                let started = DispatchTime.now().uptimeNanoseconds
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin + distance))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                editor.layoutSubtreeIfNeeded()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                try await Task.sleep(nanoseconds: 30_000_000)
                if let revision = coordinator.lastAppliedHighlightRevision { appliedRevisions.insert(revision) }
            }
        }
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.string, source)
        XCTAssertFalse(editor.undoManager?.canUndo ?? true)
        recordScrollReport("Editor scroll", ["milliseconds": samples, "highlightApplications": appliedRevisions.count])
    }

    private func requireScrollProbe() throws {
        guard ProcessInfo.processInfo.environment["PLAINSONG_RUN_SCROLL_PROBE"] == "1" else {
            throw XCTSkip("Paired scroll diagnostics are opt-in: TEST_RUNNER_PLAINSONG_RUN_SCROLL_PROBE=1")
        }
    }

    private func recordScrollReport(_ name: String, _ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let report = String(decoding: data, as: UTF8.self)
        print("\(name): \(report)")
        let attachment = XCTAttachment(string: report)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHostedPreviewScrollWorkload() async throws {
        try requireScrollProbe()
        let controller = PreviewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.webView
        window.orderFront(nil)
        defer {
            controller.shutdownForTesting()
            window.close()
        }
        try await waitUntil("preview ready", timeout: 20) { controller.isReady }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "large-1mb", withExtension: "md"))
        let source = try String(contentsOf: fixture, encoding: .utf8)
        var completedID: Int?
        controller.renderCompletionObserver = { completedID = $0.renderID }
        let renderID = controller.renderForTesting(DocumentTextChange(
            text: source, version: 0, fileKind: .markdown, fileURL: nil
        ))
        try await waitUntil("large preview rendered", timeout: 60) { completedID == renderID }
        try await controller.webView.evaluateJavaScript("""
        window.scrollProbe = null;
        (async () => {
          const root = document.getElementById('preview-root');
          const lines = [...root.querySelectorAll('[data-line]')].map(e => +e.dataset.line);
          const lastLine = Math.max(...lines);
          let queries = 0, geometryReads = 0, messages = 0;
          const query = root.querySelectorAll;
          root.querySelectorAll = function(s) { if (s === '[data-line]') queries++; return query.call(this, s); };
          const offset = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetTop');
          Object.defineProperty(HTMLElement.prototype, 'offsetTop', {configurable: true, get() {
            geometryReads++; return offset.get.call(this);
          }});
          const rect = Element.prototype.getBoundingClientRect;
          Element.prototype.getBoundingClientRect = function() { geometryReads++; return rect.call(this); };
          const bridge = window.webkit.messageHandlers.bridge;
          const post = bridge.postMessage.bind(bridge);
          bridge.postMessage = message => { if (message.name === 'previewScrolled') messages++; post(message); };
          const frame = () => new Promise(resolve => requestAnimationFrame(resolve));
          const milliseconds = [], frames = [];
          let previous = await frame();
          for (let step = 0; step < 80; step++) {
            const started = performance.now();
            const fraction = step < 40 ? step / 50 : (79 - step) / 50;
            window.PlainsongBridge.receive({name:'scrollToLine',payload:{line:Math.floor(lastLine * fraction) + 1,animated:false}});
            milliseconds.push(performance.now() - started);
            const now = await frame(); frames.push(now - previous); previous = now;
          }
          await new Promise(resolve => setTimeout(resolve, 150));
          const height = document.documentElement.scrollHeight - innerHeight;
          for (let step = 0; step < 40; step++) {
            window.scrollTo(0, height * (step < 20 ? step : 39 - step) / 25);
            await frame(); await frame();
          }
          root.querySelectorAll = query;
          Object.defineProperty(HTMLElement.prototype, 'offsetTop', offset);
          Element.prototype.getBoundingClientRect = rect;
          bridge.postMessage = post;
          window.scrollProbe = {milliseconds, frames, queries, geometryReads, messages, anchors:lines.length};
        })().catch(error => { window.scrollProbe = {error:String(error)}; });
        true;
        """)
        try await waitUntil("scroll probe completed", timeout: 60) {
            try await controller.webView.evaluateJavaScript("window.scrollProbe !== null") as? Bool == true
        }
        let value = try await controller.webView.evaluateJavaScript("window.scrollProbe")
        let report = try XCTUnwrap(value as? [String: Any])
        XCTAssertNil(report["error"])
        XCTAssertGreaterThan(report["messages"] as? Int ?? 0, 0)
        recordScrollReport("Preview scroll", report)
    }
}
