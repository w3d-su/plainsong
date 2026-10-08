import Foundation
import MarkdownCore
@testable import SyntaxKit
import XCTest

final class SyntaxProviderTests: XCTestCase {
    func testProviderEchoesIdentityAndAbsoluteUTF16Ranges() async throws {
        let source = "標題繁中 👩🏽‍💻 組合e\u{0301}\n# 後記\n"
        let heading = (source as NSString).range(of: "後記")
        let requestID = UUID()
        let request = SyntaxRequest(
            requestID: requestID,
            version: 11,
            source: source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length)
        )
        let result = try await MarkdownSyntaxTokenizer().tokens(for: request)
        XCTAssertEqual(result.requestID, requestID)
        XCTAssertEqual(result.version, 11)
        XCTAssertEqual(
            result.coveredRange,
            MarkdownSyntaxParser.visibleHighlightRange(in: source, requestedRange: request.visibleRange)
        )
        let headingTokens = result.tokens.filter {
            if case .headingText = $0.kind { return true }
            return false
        }
        XCTAssertEqual(headingTokens.count, 1)
        XCTAssertEqual(headingTokens[0].range, heading)
        XCTAssertEqual((source as NSString).substring(with: headingTokens[0].range), "後記")
        assertUTF16Boundaries(source, result.tokens)
    }

    func testViewportTokensStayAbsoluteAndDoNotSplitSurrogatesOrCombiningMarks() async throws {
        let source = "前綴\n標題繁中 👩🏽‍💻 組合e\u{0301} tail\n"
        let emoji = (source as NSString).range(of: "👩🏽‍💻")
        let request = SyntaxRequest(
            requestID: UUID(),
            version: 3,
            source: source,
            fileKind: .markdown,
            visibleRange: emoji
        )
        let result = try await MarkdownSyntaxTokenizer().tokens(for: request)
        XCTAssertGreaterThan(result.coveredRange.location, 0)
        XCTAssertLessThanOrEqual(NSMaxRange(result.coveredRange), (source as NSString).length)
        for token in result.tokens {
            XCTAssertGreaterThanOrEqual(token.range.location, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), (source as NSString).length)
            let text = (source as NSString).substring(with: token.range)
            XCTAssertFalse(text.utf16.first.map(UTF16.isTrailSurrogate) ?? false)
            if let last = text.utf16.last {
                XCTAssertFalse(UTF16.isLeadSurrogate(last) && text.utf16.count == 1)
            }
        }
        let composed = "e\u{0301}"
        let full = try MarkdownSyntaxParser().tokens(in: "# \(composed)\n", fileKind: .markdown)
        let heading = try XCTUnwrap(full.first {
            if case .headingText = $0.kind { return true }
            return false
        })
        XCTAssertEqual(("# \(composed)\n" as NSString).substring(with: heading.range), composed)
    }

    func testContextBoundariesClampAndKeepFenceYAMLAndTSXTogether() throws {
        let parser = try MarkdownSyntaxParser()

        let empty = parser.tokens(in: "", fileKind: .markdown, visibleRange: NSRange(location: 5, length: 5))
        XCTAssertEqual(empty, [])
        XCTAssertEqual(
            MarkdownSyntaxParser.visibleHighlightRange(in: "", requestedRange: NSRange(location: 5, length: 5)),
            NSRange(location: 0, length: 0)
        )

        let traditional = "abc\n"
        let eof = MarkdownSyntaxParser.visibleHighlightRange(
            in: traditional,
            requestedRange: NSRange(location: (traditional as NSString).length, length: 0)
        )
        XCTAssertLessThanOrEqual(NSMaxRange(eof), (traditional as NSString).length)

        let overflow = MarkdownSyntaxParser.visibleHighlightRange(
            in: traditional,
            requestedRange: NSRange(location: 10000, length: 40)
        )
        XCTAssertLessThanOrEqual(NSMaxRange(overflow), (traditional as NSString).length)

        let yaml = "---\ntitle: 標題\n---\n\n# 後\n"
        let yamlCovered = MarkdownSyntaxParser.visibleHighlightRange(
            in: yaml,
            requestedRange: NSRange(location: 5, length: 6)
        )
        XCTAssertEqual(yamlCovered.location, 0)
        XCTAssertGreaterThan(yamlCovered.length, 6)

        let fence = "para\n\n```ts\n" + String(repeating: "const a = 1\n", count: 40) + "```\n\nafter\n"
        let fenceCovered = MarkdownSyntaxParser.visibleHighlightRange(
            in: fence,
            requestedRange: NSRange(location: 80, length: 12)
        )
        let fenceText = (fence as NSString).substring(with: fenceCovered)
        XCTAssertTrue(fenceText.contains("```ts"))
        XCTAssertTrue(fenceText.contains("```\n"))

        let tsx = "import Button from './Button'\n\n<Button title=\"標題\">child</Button>\n"
        let tsxTokens = parser.tokens(
            in: tsx,
            fileKind: .mdx,
            visibleRange: NSRange(location: 32, length: 20)
        )
        XCTAssertTrue(tsxTokens.contains {
            switch $0.kind {
            case .tsxKeyword, .tsxTag, .tsxAttribute, .tsxString, .tsxPunctuation, .mdxSource:
                true
            default:
                false
            }
        })
        assertUTF16Boundaries(tsx, tsxTokens)

        let multiline = "before **bold\nstill** after\n"
        let inline = parser.tokens(
            in: multiline,
            fileKind: .markdown,
            visibleRange: NSRange(location: 10, length: 8)
        )
        XCTAssertTrue(inline.contains { $0.kind == .strong })
        assertUTF16Boundaries(multiline, inline)
    }

    func testFullDocumentCutoffDoesNotApplyToVisibleRangeParsing() throws {
        let paragraph = "Plain **bold** paragraph.\n"
        var source = ""
        while source.utf8.count <= MarkdownSyntaxParser.inlineParsingLimit {
            source += paragraph
        }
        source += "# Tail\n"
        let parser = try MarkdownSyntaxParser()
        let full = parser.tokens(in: source, fileKind: .markdown)
        XCTAssertFalse(full.contains { $0.kind == .strong })
        XCTAssertTrue(full.contains {
            if case .headingText = $0.kind { return true }
            return false
        })
        let tail = (source as NSString).range(of: "**bold**", options: .backwards)
        let visible = parser.tokens(in: source, fileKind: .markdown, visibleRange: tail)
        XCTAssertTrue(visible.contains { $0.kind == .strong })
    }

    func testInvalidRangeIsRejectedAndCancellationDropsBuiltTokens() async throws {
        let provider = try MarkdownSyntaxTokenizer()
        let source = "# Heading\n"
        do {
            _ = try await provider.tokens(for: SyntaxRequest(
                requestID: UUID(),
                version: 1,
                source: source,
                fileKind: .markdown,
                visibleRange: NSRange(location: NSNotFound, length: 1)
            ))
            XCTFail("expected invalidRange")
        } catch let failure as SyntaxFailure {
            XCTAssertEqual(failure, .invalidRange)
        }

        let cancelling = try MarkdownSyntaxTokenizer(cancellingBeforeReturn: true)
        do {
            _ = try await cancelling.tokens(for: SyntaxRequest(
                requestID: UUID(),
                version: 2,
                source: source,
                fileKind: .markdown,
                visibleRange: NSRange(location: 0, length: (source as NSString).length)
            ))
            XCTFail("expected cancellation to discard the result")
        } catch is CancellationError {}
    }

    func testConcurrentRequestsDoNotCrossParserState() async throws {
        let provider = try MarkdownSyntaxTokenizer()
        let sources = (0 ..< 24).map { index in
            "paragraph \(index)\n\n# Heading \(index)\n\n**bold \(index)**\n"
        }
        let results = try await withThrowingTaskGroup(of: ConcurrentSyntaxSample.self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    let request = SyntaxRequest(
                        requestID: UUID(),
                        version: index,
                        source: source,
                        fileKind: .markdown,
                        visibleRange: NSRange(location: 0, length: (source as NSString).length)
                    )
                    let result = try await provider.tokens(for: request)
                    let serial = try MarkdownSyntaxParser().tokens(
                        in: source,
                        fileKind: .markdown,
                        visibleRange: request.visibleRange
                    )
                    return ConcurrentSyntaxSample(index: index, result: result, serial: serial)
                }
            }
            var collected: [ConcurrentSyntaxSample] = []
            for try await item in group {
                collected.append(item)
            }
            return collected
        }

        XCTAssertEqual(results.count, sources.count)
        for sample in results {
            let index = sample.index
            let result = sample.result
            let serial = sample.serial
            XCTAssertEqual(result.version, index)
            XCTAssertEqual(result.tokens, serial)
            let heading = try XCTUnwrap(result.tokens.first {
                if case .headingText = $0.kind { return true }
                return false
            })
            XCTAssertEqual(
                (sources[index] as NSString).substring(with: heading.range),
                "Heading \(index)"
            )
            assertSorted(result.tokens)
        }
    }

    private struct ConcurrentSyntaxSample {
        var index: Int
        var result: SyntaxResult
        var serial: [MarkdownSyntaxToken]
    }

    private func assertUTF16Boundaries(_ source: String, _ tokens: [MarkdownSyntaxToken]) {
        let units = Array(source.utf16)
        let limit = (source as NSString).length
        for token in tokens {
            XCTAssertGreaterThan(token.range.length, 0)
            XCTAssertGreaterThanOrEqual(token.range.location, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), limit)
            if token.range.location < units.count {
                XCTAssertFalse(UTF16.isTrailSurrogate(units[token.range.location]))
            }
            let end = NSMaxRange(token.range)
            if end < units.count {
                XCTAssertFalse(UTF16.isTrailSurrogate(units[end]))
            }
        }
        assertSorted(tokens)
    }

    private func assertSorted(_ tokens: [MarkdownSyntaxToken]) {
        for (previous, current) in zip(tokens, tokens.dropFirst()) {
            if previous.range.location == current.range.location {
                XCTAssertGreaterThanOrEqual(previous.range.length, current.range.length)
            } else {
                XCTAssertLessThan(previous.range.location, current.range.location)
            }
        }
    }
}
