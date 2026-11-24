@testable import MarkdownCore
import XCTest

/// Codebase review, Medium: completion ranges after indentation that carries a combining scalar.
final class CompletionEngineCombiningIndentTests: XCTestCase {
    func testLineStartContextIsOffWhenACombiningScalarFollowsTheIndentation() {
        // " \u{301}" is one Character, so a Character offset skipped the mark while the
        // replacement range still covered it.
        XCTAssertTrue(completions(from: " \u{301}#<caret>").isEmpty)
        XCTAssertTrue(completions(from: " \u{301}```sw<caret>").isEmpty)
    }

    func testFrontmatterKeyContextIsOffWhenACombiningScalarFollowsTheIndentation() {
        XCTAssertTrue(completions(from: "---\n \u{301}ti<caret>\n---\n").isEmpty)
    }

    func testIndentedLineStartContextStillReplacesOnlyTheQuery() {
        let results = completions(from: "  #<caret>")
        XCTAssertEqual(results.first?.replacementRange, NSRange(location: 2, length: 1))
    }

    private func completions(from marked: String) -> [Completion] {
        let cursor = (marked as NSString).range(of: "<caret>").location
        let text = marked.replacingOccurrences(of: "<caret>", with: "")
        return CompletionEngine().complete(
            text: text,
            cursor: cursor,
            workspace: CompletionWorkspace(currentFilePath: "posts/new.md")
        )
    }
}
