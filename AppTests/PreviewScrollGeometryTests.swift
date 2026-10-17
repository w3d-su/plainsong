import AppKit
import MarkdownCore
@testable import PreviewKit
import XCTest

@MainActor
final class PreviewScrollGeometryTests: XCTestCase {
    func testWarmBridgeScrollingAvoidsDOMQueriesAndSameTurnMutationRefreshesGeometry() async throws {
        let controller = PreviewController()
        defer { controller.shutdownForTesting() }
        controller.webView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        try await render(source: String(repeating: "Paragraph\n\n", count: 200), in: controller)
        let result = try await controller.webView.evaluateJavaScript("""
        (() => {
          const root = document.getElementById('preview-root');
          const target = root.querySelector('[data-line="201"]');
          const scroll = line => window.PlainsongBridge.receive({name:'scrollToLine',payload:{line,animated:false}});
          scroll(201);
          const before = target.getBoundingClientRect().top;
          let queries = 0;
          const query = root.querySelectorAll;
          root.querySelectorAll = function(s) { queries++; return query.call(this,s); };
          for (let line = 101; line <= 201; line += 2) scroll(line);
          root.querySelectorAll = query;
          const spacer = document.createElement('div');
          spacer.style.height = '250px';
          root.insertBefore(spacer, target);
          // No timer/observer turn between mutation and the next bridge request.
          scroll(201);
          return {before, after:target.getBoundingClientRect().top, queries};
        })()
        """)
        let values = try XCTUnwrap(result as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(values["before"]), 12, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(values["after"]), 12, accuracy: 2)
        XCTAssertEqual(values["queries"], 0)
    }

    func testNestedOffsetParentsAndResizeKeepSourceTargetsAligned() async throws {
        let controller = PreviewController()
        defer { controller.shutdownForTesting() }
        controller.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        let source = String(repeating: "A long paragraph with wrapping text and **bold** words.\n\n", count: 200)
        try await render(source: source, in: controller)
        let script = """
        (() => {
          const target = document.querySelector('[data-line="201"]');
          window.PlainsongBridge.receive({name:'scrollToLine',payload:{line:201,animated:false}});
          return target.getBoundingClientRect().top;
        })()
        """
        // Reparent a target into a positioned block. This reproduces the coordinate
        // mismatch in table/MDX descendants whose offsetTop is not document-relative.
        try await controller.webView.evaluateJavaScript("""
        const target = document.querySelector('[data-line="201"]');
        const wrapper = document.createElement('div');
        wrapper.style.position = 'relative';
        target.replaceWith(wrapper);
        wrapper.append(target);
        true;
        """)
        let initial = try await controller.webView.evaluateJavaScript(script) as? Double
        XCTAssertEqual(try XCTUnwrap(initial), 12, accuracy: 2)
        controller.webView.frame.size.width = 300
        // Wait for WebKit's resize event/layout before requesting the new mapping.
        try await waitUntil {
            try await controller.webView.evaluateJavaScript("innerWidth === 300") as? Bool == true
        }
        let resized = try await controller.webView.evaluateJavaScript(script) as? Double
        XCTAssertEqual(try XCTUnwrap(resized), 12, accuracy: 2)
    }

    /// The editor's top line often survives a window resize, so no new `scrollToLine`
    /// arrives; the preview must keep that line in place across its own reflow.
    func testWidthChangeKeepsTheSyncedLineInPlaceWithoutANewRequest() async throws {
        let controller = PreviewController()
        defer { controller.shutdownForTesting() }
        controller.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        let source = String(repeating: "A long paragraph with wrapping text and **bold** words.\n\n", count: 200)
        try await render(source: source, in: controller)
        let targetTop = "document.querySelector('[data-line=\"201\"]').getBoundingClientRect().top"
        let initial = try await controller.webView.evaluateJavaScript("""
        window.PlainsongBridge.receive({name:'scrollToLine',payload:{line:201,animated:false}});
        \(targetTop)
        """) as? Double
        XCTAssertEqual(try XCTUnwrap(initial), 12, accuracy: 2)
        let scrollBefore = try await controller.webView.evaluateJavaScript("scrollY") as? Double
        for width in [420, 300, 360] {
            controller.webView.frame.size.width = CGFloat(width)
            // The resize observer runs in a later rendering update; poll across frames.
            try await waitUntil {
                try await controller.webView.evaluateJavaScript(
                    "innerWidth === \(width) && Math.abs(\(targetTop) - 12) <= 2"
                ) as? Bool == true
            }
        }
        let scrollAfter = try await controller.webView.evaluateJavaScript("scrollY") as? Double
        XCTAssertNotEqual(scrollBefore, scrollAfter, "the reflow must actually have moved the content")
    }

    private func render(source: String, in controller: PreviewController) async throws {
        try await waitUntil { controller.isReady }
        var completed: Int?
        controller.renderCompletionObserver = { completed = $0.renderID }
        let renderID = controller.renderForTesting(DocumentTextChange(
            text: source, version: 0, fileKind: .markdown, fileURL: nil
        ))
        try await waitUntil { completed == renderID }
    }

    private func waitUntil(_ condition: @escaping @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for preview scroll geometry")
        throw CocoaError(.coderInvalidValue)
    }
}
