import AppKit
@testable import EditorKit
import MarkdownCore
import SwiftTreeSitter
@testable import SyntaxKit
import XCTest

final class MDXInlineDuplicateBenchTests: XCTestCase {
    private var sink = 0

    private func sample(_ count: Int, _ body: () throws -> Int) rethrows -> [Double] {
        for _ in 0..<5 { sink &+= try body() }
        return try (0..<count).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            sink &+= try autoreleasepool(invoking: body)
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
    }

    private func report(_ bytes: Int, _ mode: String, _ times: [Double]) {
        let sorted = times.sorted()
        print(String(format: "BENCH,%d,%@,%d,%.6f,%.6f", bytes, mode, times.count,
                     sorted[sorted.count / 2], sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]))
    }

    private func inlineNodes(_ node: Node) -> [Node] {
        if node.nodeType == "inline" { return [node] }
        if ["fenced_code_block", "indented_code_block", "minus_metadata", "plus_metadata"].contains(node.nodeType ?? "") { return [] }
        return (0..<node.childCount).flatMap { index in
            node.child(at: index).map(inlineNodes) ?? []
        }
    }

    @MainActor
    func testBenchmark() async throws {
        print("BENCH,bytes,mode,n,median_ms,p95_ms")
        let unit = """
        ## Building a component guide

        In this tutorial, **strong defaults** and *small changes* make [the guide](https://example.com/docs) useful. Try `npm run build` with <Badge tone="success">ready</Badge>, then <Counter initial={3} /> beside ~~outdated advice~~. Read [the API](https://example.com/api) for **nested *emphasis*** and `const value = 42` examples.

        <Callout kind="tip" title="Shipping">
        Use **typed props** with [Astro](https://astro.build) and *clear prose* around `render()`.
        </Callout>

        """ + "\n"
        for target in [1024, 10240, 102400, 1048576] {
            let source = String(repeating: unit, count: max(1, target / unit.utf8.count))
            let bytes = source.utf8.count
            let parser = try MarkdownSyntaxParser()
            let whole = NSRange(location: 0, length: (source as NSString).length)
            let tree = try XCTUnwrap(parser.markdownParser.parse(source))
            let nodes = inlineNodes(try XCTUnwrap(tree.rootNode))
            let strings = nodes.compactMap(\.text)
            XCTAssertFalse(strings.isEmpty)
            let tokens = parser.tokens(in: source, fileKind: .mdx, expandedVisibleRange: whole)
            XCTAssertTrue(tokens.contains { $0.kind == .tsxTag })
            XCTAssertTrue(tokens.contains { $0.kind == .strong })
            print("META,\(bytes),inline_nodes,\(nodes.count),inline_utf8,\(strings.reduce(0) { $0 + $1.utf8.count })")
            report(bytes, "full_current_forced_inline", sample(60) {
                parser.tokens(in: source, fileKind: .mdx, expandedVisibleRange: whole).count
            })
            report(bytes, "full_one_inline_pass_parse_only", sample(60) {
                strings.reduce(0) { $0 + Int(parser.inlineParser.parse($1)?.rootNode?.byteRange.upperBound ?? 0) }
            })
            report(bytes, "full_one_inline_pass_with_extraction", sample(60) {
                nodes.reduce(0) { value, node in
                    guard let text = node.text, !text.isEmpty else { return value }
                    return value + Int(parser.inlineParser.parse(text)?.rootNode?.byteRange.upperBound ?? 0)
                }
            })
            report(bytes, "full_public_API_cutoff", sample(60) {
                parser.tokens(in: source, fileKind: .mdx).count
            })

            let location = (source as NSString).range(of: "tutorial", options: [], range: NSRange(location: whole.length / 2, length: whole.length - whole.length / 2)).location
            XCTAssertNotEqual(location, NSNotFound)
            let variants = ["x", "y"].map { (source as NSString).replacingCharacters(in: NSRange(location: location, length: 1), with: $0) }
            let viewport = NSRange(location: max(0, location - 1024), length: min(2048, whole.length - max(0, location - 1024)))
            let range = MarkdownSyntaxParser.visibleHighlightRange(in: variants[0], requestedRange: viewport)
            let fragment = (variants[0] as NSString).substring(with: range)
            let visibleTree = try XCTUnwrap(parser.markdownParser.parse(fragment))
            let visibleNodes = inlineNodes(try XCTUnwrap(visibleTree.rootNode))
            print("META,\(bytes),viewport,\(viewport),expanded,\(range),visible_inline_nodes,\(visibleNodes.count)")
            report(bytes, "edit_duplicate_inline_with_extraction", sample(200) {
                visibleNodes.reduce(0) { value, node in
                    guard let text = node.text, !text.isEmpty else { return value }
                    return value + Int(parser.inlineParser.parse(text)?.rootNode?.byteRange.upperBound ?? 0)
                }
            })
            var index = 0
            report(bytes, "edit_source_parser_total", sample(200) {
                index += 1
                return parser.tokens(in: variants[index % 2], fileKind: .mdx, visibleRange: viewport).count
            })
            let highlighter = MarkdownSyntaxHighlighter()
            report(bytes, "edit_source_highlighter_total", sample(200) {
                index += 1
                return highlighter.highlight(variants[index % 2], fileKind: .mdx, visibleRange: viewport, parser: parser).text.characters.count
            })
            report(bytes, "edit_fold_parser_total", sample(200) {
                index += 1
                return parser.visibleTokensAndFoldPlan(in: variants[index % 2], fileKind: .mdx, visibleRange: viewport, selection: NSRange(location: location + 1, length: 0)).tokens.count
            })
            report(bytes, "edit_fold_highlighter_total", sample(200) {
                index += 1
                return highlighter.highlight(variants[index % 2], fileKind: .mdx, visibleRange: viewport, parser: parser, developmentPresentation: .inlineFoldReveal, selection: NSRange(location: location + 1, length: 0)).text.characters.count
            })
            let scrollView = MarkdownSTTextView.scrollableTextView()
            scrollView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
            textView.frame = scrollView.bounds
            var applied: [Double] = []
            for iteration in 0..<105 {
                let edited = variants[iteration % 2]
                textView.text = edited
                textView.textSelection = NSRange(location: location + 1, length: 0)
                scrollView.layoutSubtreeIfNeeded()
                let start = DispatchTime.now().uptimeNanoseconds
                let result = highlighter.highlight(edited, fileKind: .mdx, visibleRange: viewport, parser: parser)
                let didApply = MarkdownTextView.applyHighlightedText(HighlightedText(revision: iteration, range: result.range, text: result.text, foldPlan: result.foldPlan), to: textView)
                scrollView.displayIfNeeded()
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                XCTAssertTrue(didApply)
                if iteration >= 5 { applied.append(elapsed) }
            }
            report(bytes, "edit_source_highlight_apply_display_main", applied)
        }
        print("BENCH_SINK,\(sink)")
    }
}
