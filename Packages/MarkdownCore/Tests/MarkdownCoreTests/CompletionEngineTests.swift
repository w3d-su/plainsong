@testable import MarkdownCore
import XCTest

final class CompletionEngineTests: XCTestCase {
    func testLineStartSnippetContexts() {
        let workspace = CompletionWorkspace(currentFilePath: "posts/new.md")

        let topOfFile = completions(from: "#<caret>", workspace: workspace)
        XCTAssertTrue(topOfFile.containsLabel("Heading 1"))
        XCTAssertTrue(topOfFile.containsLabel("Task Item"))
        XCTAssertTrue(topOfFile.containsLabel("Table"))
        XCTAssertTrue(topOfFile.containsLabel("Frontmatter Block"))
        XCTAssertEqual(topOfFile.first(named: "Heading 1")?.replacementRange, NSRange(location: 0, length: 1))

        let afterBody = completions(from: "Body\n#<caret>", workspace: workspace)
        XCTAssertTrue(afterBody.containsLabel("Heading 1"))
        XCTAssertFalse(afterBody.containsLabel("Frontmatter Block"))
    }

    func testFenceInfoLanguageContext() {
        let results = completions(from: "```sw<caret>")

        XCTAssertEqual(results.first?.label, "swift")
        XCTAssertEqual(results.first?.insertText, "swift")
        XCTAssertEqual(results.first?.replacementRange, NSRange(location: 3, length: 2))

        let tildeResults = completions(from: "~~~py<caret>")
        XCTAssertEqual(tildeResults.first?.label, "python")
        XCTAssertEqual(tildeResults.first?.replacementRange, NSRange(location: 3, length: 2))
    }

    func testLinkDestinationContextSuggestsFilesImagesAndAnchors() {
        let workspace = CompletionWorkspace(
            currentFilePath: "posts/current.md",
            markdownFilePaths: ["posts/hello.md", "notes/release.md"],
            imageFilePaths: ["assets/hero.png"],
            currentFileHeadingAnchors: ["#intro-section"]
        )

        let fileResults = completions(from: "See [post](./po<caret>)", workspace: workspace)
        XCTAssertTrue(fileResults.containsLabel("./posts/hello.md"))
        XCTAssertEqual(fileResults.first(named: "./posts/hello.md")?.insertText, "./posts/hello.md")
        XCTAssertFalse(fileResults.containsLabel("notes/release.md"))
        XCTAssertTrue(fileResults.contains { $0.kind == .filePath })

        let anchorResults = completions(from: "See [section](#in<caret>)", workspace: workspace)
        XCTAssertEqual(anchorResults.first?.label, "#intro-section")
        XCTAssertEqual(anchorResults.first?.kind, .headingAnchor)

        let emptyQueryResults = completions(from: "See [all](<caret>)", workspace: workspace)
        XCTAssertTrue(emptyQueryResults.containsLabel("posts/hello.md"))
        XCTAssertTrue(emptyQueryResults.containsLabel("notes/release.md"))
        XCTAssertTrue(emptyQueryResults.containsLabel("assets/hero.png"))
        XCTAssertTrue(emptyQueryResults.containsLabel("#intro-section"))
    }

    func testLinkDestinationIgnoresOrphanParentheses() {
        let workspace = CompletionWorkspace(markdownFilePaths: ["post.md"])
        let results = completions(from: "text (aside) then [link](<caret>)", workspace: workspace)

        XCTAssertTrue(results.containsLabel("post.md"))
    }

    func testImageDestinationContextSuggestsOnlyImages() {
        let workspace = CompletionWorkspace(
            markdownFilePaths: ["posts/hello.md"],
            imageFilePaths: ["assets/hero.png", "assets/icon.svg"]
        )

        let results = completions(from: "![](assets/h<caret>)", workspace: workspace)
        XCTAssertEqual(results.map(\.label), ["assets/hero.png"])
        XCTAssertEqual(results.first?.kind, .imagePath)
        XCTAssertFalse(results.containsLabel("posts/hello.md"))

        let fuzzyResults = completions(from: "![](hro<caret>)", workspace: workspace)
        XCTAssertEqual(fuzzyResults.first?.label, "assets/hero.png")
    }

    func testEmojiShortcodeContextInsertsUnicodeCharacter() {
        let results = completions(from: "Mood :sm<caret>")

        XCTAssertEqual(results.first?.label, ":smile:")
        XCTAssertEqual(results.first?.insertText, "😄")
        XCTAssertEqual(results.first?.replacementRange, NSRange(location: 5, length: 3))
    }

    func testFrontmatterKeyContextIncludesBuiltInAndLearnedKeys() {
        let workspace = CompletionWorkspace(frontmatterKeys: ["layout", "summary", "title"])

        let titleResults = completions(from: "---\nti<caret>\n---\nBody", workspace: workspace)
        XCTAssertEqual(titleResults.first?.label, "title")
        XCTAssertEqual(titleResults.first?.insertText, "title: ")
        XCTAssertEqual(titleResults.first?.kind, .frontmatterKey)

        let allKeyResults = completions(from: "---\n<caret>\n---\nBody", workspace: workspace)
        XCTAssertTrue(allKeyResults.containsLabel("draft"))
        XCTAssertTrue(allKeyResults.containsLabel("layout"))
        XCTAssertEqual(allKeyResults.count(named: "title"), 1)
    }

    func testFrontmatterKeyContextIgnoresDelimiterLines() {
        let workspace = CompletionWorkspace(frontmatterKeys: ["layout"])

        let openingDelimiterResults = completions(from: "<caret>---\ntitle: Post\n---\nBody", workspace: workspace)
        XCTAssertFalse(openingDelimiterResults.contains { $0.kind == .frontmatterKey })

        let closingDelimiterResults = completions(from: "---\ntitle: Post\n<caret>---\nBody", workspace: workspace)
        XCTAssertFalse(closingDelimiterResults.contains { $0.kind == .frontmatterKey })
    }

    func testMDXComponentContextScansImportLines() {
        let workspace = CompletionWorkspace(currentFilePath: "posts/page.mdx")
        let text = """
        import Card, {Hero as LandingHero, CTA} from "./components"
        import {FeatureGrid} from "./FeatureGrid"

        <Ca<caret>
        """

        let results = completions(from: text, workspace: workspace)

        XCTAssertEqual(results.first?.label, "Card")
        XCTAssertEqual(results.first?.insertText, "Card")
        XCTAssertEqual(results.first?.kind, .component)
        XCTAssertFalse(results.containsLabel("Hero"))
        XCTAssertTrue(results.containsLabel("CTA"))
    }

    func testRankingBoostsRecentlyUsedPrefixMatchesAndCapsResults() {
        let markdownPaths = (0 ..< 70).map { String(format: "posts/%03d.md", $0) }
        let workspace = CompletionWorkspace(
            markdownFilePaths: markdownPaths + ["docs/postscript.md"],
            recentlyUsedCompletionIDs: ["filePath:posts/049.md"]
        )

        let results = completions(from: "[link](po<caret>)", workspace: workspace)

        XCTAssertEqual(results.count, 50)
        XCTAssertEqual(results.first?.label, "posts/049.md")
        XCTAssertFalse(results.containsLabel("docs/postscript.md"))
    }

    func testRankingUsesRecentCompletionOrderForEqualMatches() {
        let workspace = CompletionWorkspace(
            markdownFilePaths: ["posts/a.md", "posts/z.md"],
            recentlyUsedCompletionIDs: ["filePath:posts/z.md", "filePath:posts/a.md"]
        )

        let results = completions(from: "[link](<caret>)", workspace: workspace)

        XCTAssertEqual(results.map(\.label), ["posts/z.md", "posts/a.md"])
    }

    func testRankingDoesNotPenalizeOlderRecentIDsWhenRecentListExceedsBoostWindow() {
        let olderRecentID = "filePath:posts/a-recent.md"
        let workspace = CompletionWorkspace(
            markdownFilePaths: ["posts/a-recent.md", "posts/z-never.md"],
            recentlyUsedCompletionIDs: (0 ..< 260).map { "filePath:posts/dummy-\($0).md" } + [olderRecentID]
        )

        let results = completions(from: "[link](<caret>)", workspace: workspace)

        XCTAssertLessThan(
            results.firstIndex { $0.id == olderRecentID } ?? Int.max,
            results.firstIndex { $0.id == "filePath:posts/z-never.md" } ?? Int.max
        )
    }

    func testCompletionContextMissIsCheapOnLargeDocuments() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/large-1mb.md")
        let largeText = try String(contentsOf: fixtureURL, encoding: .utf8) + "\nordinary paragraph"
        let cursor = (largeText as NSString).length

        let start = ContinuousClock.now
        let results = CompletionEngine().complete(text: largeText, cursor: cursor, workspace: .empty)
        let duration = start.duration(to: .now)

        XCTAssertTrue(results.isEmpty)
        XCTAssertLessThan(duration, .milliseconds(16))
    }

    private func completions(
        from rawText: String,
        workspace: CompletionWorkspace = .empty,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [Completion] {
        guard let marker = rawText.range(of: "<caret>") else {
            XCTFail("Missing caret marker", file: file, line: line)
            return []
        }

        var text = rawText
        text.removeSubrange(marker)
        let cursor = rawText[..<marker.lowerBound].utf16.count
        return CompletionEngine().complete(text: text, cursor: cursor, workspace: workspace)
    }
}

private extension [Completion] {
    func containsLabel(_ label: String) -> Bool {
        contains { $0.label == label }
    }

    func first(named label: String) -> Completion? {
        first { $0.label == label }
    }

    func count(named label: String) -> Int {
        filter { $0.label == label }.count
    }
}
