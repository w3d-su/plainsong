import AppKit
@testable import EditorKit
@testable import Plainsong
import XCTest

/// Settings › Editor drives EditorKit's line-number gutter in the mounted workspace.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedLineNumberSettingAndThemeUpdateTheGutterLive() async throws {
        let source = (1 ... 40).map { "Line \($0) of the hosted gutter fixture." }.joined(separator: "\n")
        let hosted = try await makeHostedEditorWorkspace(source: source)
        let editor = try hostedEditor(hosted)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView as? EditorScrollView)
        let gutter = try XCTUnwrap(editor.lineNumberGutter, "line numbers are on by default")
        XCTAssertFalse(editor.showsLineNumbers, "STTextView's own gutter stays off")
        XCTAssertNil(editor.gutterView)
        XCTAssertTrue(scrollView.lineNumberGutter === gutter)
        XCTAssertEqual(scrollView.contentView.frame.minX, gutter.frame.maxX)
        XCTAssertEqual(gutter.style.textColor, MarkdownSyntaxTheme.standard.mutedColor)

        hosted.appState.preferences.setEditorTheme(.graphite)
        try await waitUntil("the gutter follows the editor theme") {
            editor.lineNumberGutter?.style.textColor == MarkdownSyntaxTheme.graphite.mutedColor
        }
        XCTAssertTrue(editor.lineNumberGutter === gutter, "a theme change restyles the same gutter")

        hosted.appState.preferences.setShowsLineNumbers(false)
        try await waitUntil("hiding line numbers removes the gutter") {
            editor.lineNumberGutter == nil && scrollView.lineNumberGutter == nil
        }
        XCTAssertEqual(scrollView.contentView.frame.minX, 0)
        XCTAssertNil(editor.gutterView)

        hosted.appState.preferences.setShowsLineNumbers(true)
        try await waitUntil("showing line numbers restores the gutter") {
            editor.lineNumberGutter != nil
        }
        let restored = try XCTUnwrap(editor.lineNumberGutter)
        XCTAssertEqual(scrollView.contentView.frame.minX, restored.frame.maxX)
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor)?.string, source)
    }
}
