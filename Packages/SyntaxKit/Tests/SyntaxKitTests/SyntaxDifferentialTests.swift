import Foundation
import MarkdownCore
import SyntaxKit
import XCTest

final class SyntaxDifferentialTests: XCTestCase {
    func testMovedParserMatchesPreMoveBaseline() throws {
        let actual = try SyntaxBaselineRenderer().data()
        let url = SyntaxBaselineRenderer.repoRoot.appending(path: "docs/ios/evidence/lane-02/pre-move-baseline.json")
        let expected = try Data(contentsOf: url)
        XCTAssertEqual(actual, expected)
    }
}

/// Shared snapshot shape for the pre-move Mac parser and the extracted SyntaxKit parser.
/// Both sides must build these cases in the same order and encode with sorted keys.
struct SyntaxBaselineRenderer {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document())
    }

    func document() throws -> SyntaxBaselineDocument {
        let parser = try MarkdownSyntaxParser()
        let folds = WYSIWYGFoldParser(parser: parser)
        return try SyntaxBaselineDocument(cases: cases().map { spec in
            let full = parser.tokens(in: spec.source, fileKind: spec.fileKind)
            let visible = parser.tokens(
                in: spec.source,
                fileKind: spec.fileKind,
                visibleRange: spec.visibleRange
            )
            let covered = MarkdownSyntaxParser.visibleHighlightRange(
                in: spec.source,
                requestedRange: spec.visibleRange
            )
            let plan = folds.foldPlan(
                in: spec.source,
                fileKind: spec.fileKind,
                visibleRange: spec.visibleRange,
                selection: spec.selection
            )
            return SyntaxBaselineCase(
                name: spec.name,
                fileKind: spec.fileKind.rawValue,
                visibleRequest: SyntaxBaselineRange(spec.visibleRange),
                selection: SyntaxBaselineRange(spec.selection),
                covered: SyntaxBaselineRange(covered),
                fullTokens: full.map(SyntaxBaselineToken.init),
                visibleTokens: visible.map(SyntaxBaselineToken.init),
                fold: SyntaxBaselineFold(plan)
            )
        })
    }

    func cases() throws -> [SyntaxBaselineSpec] {
        var specs: [SyntaxBaselineSpec] = []
        for (name, kind) in [
            ("kitchen-sink.md", FileKind.markdown),
            ("kitchen-sink.mdx", FileKind.mdx),
            ("product-page.mdx", FileKind.mdx),
        ] as [(String, FileKind)] {
            let source = try String(
                contentsOf: SyntaxBaselineRenderer.repoRoot.appending(path: "Fixtures/\(name)"),
                encoding: .utf8
            )
            let length = (source as NSString).length
            let middle = NSRange(location: length / 3, length: min(24, max(0, length - length / 3)))
            specs.append(SyntaxBaselineSpec(
                name: "fixture-full-\(name)",
                source: source,
                fileKind: kind,
                visibleRange: NSRange(location: 0, length: length),
                selection: NSRange(location: 0, length: 0)
            ))
            specs.append(SyntaxBaselineSpec(
                name: "fixture-viewport-\(name)",
                source: source,
                fileKind: kind,
                visibleRange: middle,
                selection: NSRange(location: middle.location + min(2, middle.length), length: 0)
            ))
        }

        let traditional = "標題繁中 👩🏽‍💻 組合e\u{0301}\n第二行\n"
        let traditionalLength = (traditional as NSString).length
        let emoji = (traditional as NSString).range(of: "👩🏽‍💻")
        specs.append(contentsOf: [
            spec(
                "unicode-full",
                traditional,
                .markdown,
                NSRange(location: 0, length: traditionalLength),
                NSRange(location: emoji.location, length: 0)
            ),
            spec(
                "unicode-viewport-emoji",
                traditional,
                .markdown,
                emoji,
                NSRange(location: emoji.location, length: emoji.length)
            ),
            spec(
                "crlf-fence",
                "```swift\r\nlet x = 1\r\n```\r\n",
                .markdown,
                NSRange(location: 8, length: 4),
                NSRange(location: 0, length: 0)
            ),
            spec(
                "yaml-viewport",
                "---\ntitle: 標題\n---\n\n# 後\n",
                .markdown,
                NSRange(location: 5, length: 6),
                NSRange(location: 0, length: 0)
            ),
            spec(
                "long-fence-viewport",
                "para\n\n```ts\n" + String(repeating: "const a = 1\n", count: 40) + "```\n\nafter\n",
                .markdown,
                NSRange(location: 80, length: 12),
                NSRange(location: 0, length: 0)
            ),
            spec(
                "tsx-viewport",
                "import Button from './Button'\n\n<Button title=\"標題\">child</Button>\n",
                .mdx,
                NSRange(location: 32, length: 20),
                NSRange(location: 40, length: 0)
            ),
            spec(
                "multiline-emphasis",
                "before **bold\nstill** after\n",
                .markdown,
                NSRange(location: 10, length: 8),
                NSRange(location: 12, length: 0)
            ),
            spec("empty", "", .markdown, NSRange(location: 0, length: 0), NSRange(location: 0, length: 0)),
            spec("eof-caret", "abc\n", .markdown, NSRange(location: 4, length: 0), NSRange(location: 4, length: 0)),
            spec(
                "out-of-range",
                traditional,
                .markdown,
                NSRange(location: 10000, length: 40),
                NSRange(location: 0, length: 0)
            ),
        ])
        return specs
    }

    private func spec(
        _ name: String,
        _ source: String,
        _ fileKind: FileKind,
        _ visibleRange: NSRange,
        _ selection: NSRange
    ) -> SyntaxBaselineSpec {
        SyntaxBaselineSpec(
            name: name,
            source: source,
            fileKind: fileKind,
            visibleRange: visibleRange,
            selection: selection
        )
    }
}

struct SyntaxBaselineSpec {
    var name: String
    var source: String
    var fileKind: FileKind
    var visibleRange: NSRange
    var selection: NSRange
}

struct SyntaxBaselineDocument: Codable, Equatable {
    var cases: [SyntaxBaselineCase]
}

struct SyntaxBaselineCase: Codable, Equatable {
    var name: String
    var fileKind: String
    var visibleRequest: SyntaxBaselineRange
    var selection: SyntaxBaselineRange
    var covered: SyntaxBaselineRange
    var fullTokens: [SyntaxBaselineToken]
    var visibleTokens: [SyntaxBaselineToken]
    var fold: SyntaxBaselineFold
}

struct SyntaxBaselineRange: Codable, Equatable {
    var location: Int
    var length: Int

    init(_ range: NSRange) {
        location = range.location
        length = range.length
    }
}

struct SyntaxBaselineToken: Codable, Equatable {
    var kind: String
    var location: Int
    var length: Int

    init(_ token: MarkdownSyntaxToken) {
        kind = Self.kindName(token.kind)
        location = token.range.location
        length = token.range.length
    }

    static func kindName(_ kind: MarkdownSyntaxToken.Kind) -> String {
        if case let .headingText(level) = kind {
            return "headingText:\(level)"
        }
        return blockKindName(kind) ?? inlineKindName(kind) ?? trailingKindName(kind)
    }

    private static func blockKindName(_ kind: MarkdownSyntaxToken.Kind) -> String? {
        switch kind {
        case .frontmatter: "frontmatter"
        case .frontmatterKey: "frontmatterKey"
        case .headingMarker: "headingMarker"
        case .listMarker: "listMarker"
        case .codeBlock: "codeBlock"
        case .codeFenceMarker: "codeFenceMarker"
        case .codeFenceInfo: "codeFenceInfo"
        default: nil
        }
    }

    private static func inlineKindName(_ kind: MarkdownSyntaxToken.Kind) -> String? {
        switch kind {
        case .inlineCode: "inlineCode"
        case .strong: "strong"
        case .emphasis: "emphasis"
        case .linkText: "linkText"
        case .linkDestination: "linkDestination"
        case .quoteMarker: "quoteMarker"
        default: nil
        }
    }

    private static func trailingKindName(_ kind: MarkdownSyntaxToken.Kind) -> String {
        switch kind {
        case .tableHeader: "tableHeader"
        case .tableDelimiter: "tableDelimiter"
        case .tablePipe: "tablePipe"
        case .mdxSource: "mdxSource"
        case .tsxKeyword: "tsxKeyword"
        case .tsxString: "tsxString"
        case .tsxTag: "tsxTag"
        case .tsxAttribute: "tsxAttribute"
        case .tsxPunctuation: "tsxPunctuation"
        default:
            preconditionFailure("baseline kind already encoded")
        }
    }
}

struct SyntaxBaselineFold: Codable, Equatable {
    var visibleLocation: Int
    var visibleLength: Int
    var linkFoldingEnabled: Bool
    var regions: [SyntaxBaselineRegion]
    var images: [SyntaxBaselineImage]

    init(_ plan: WYSIWYGFoldPlan) {
        visibleLocation = plan.visibleRange.location
        visibleLength = plan.visibleRange.length
        linkFoldingEnabled = plan.linkFoldingEnabled
        regions = plan.regions.map(SyntaxBaselineRegion.init)
        images = plan.imageRegions.map(SyntaxBaselineImage.init)
    }
}

struct SyntaxBaselineRegion: Codable, Equatable {
    var kind: String
    var source: SyntaxBaselineRange
    var content: SyntaxBaselineRange
    var reveal: SyntaxBaselineRange
    var folds: [SyntaxBaselineRange]
    var revealed: Bool

    init(_ region: WYSIWYGFoldRegion) {
        kind = switch region.kind {
        case let .heading(level): "heading:\(level)"
        case .strong: "strong"
        case .emphasis: "emphasis"
        case .strikethrough: "strikethrough"
        case .inlineCode: "inlineCode"
        case .link: "link"
        }
        source = SyntaxBaselineRange(region.sourceRange)
        content = SyntaxBaselineRange(region.contentRange)
        reveal = SyntaxBaselineRange(region.revealRange)
        folds = region.foldRanges.map(SyntaxBaselineRange.init)
        revealed = region.isRevealed
    }
}

struct SyntaxBaselineImage: Codable, Equatable {
    var source: SyntaxBaselineRange
    var alt: SyntaxBaselineRange
    var path: SyntaxBaselineRange
    var title: SyntaxBaselineRange?

    init(_ region: MarkdownInlineImageRegion) {
        source = SyntaxBaselineRange(region.sourceRange)
        alt = SyntaxBaselineRange(region.altTextRange)
        path = SyntaxBaselineRange(region.sourcePathRange)
        title = region.titleRange.map(SyntaxBaselineRange.init)
    }
}
