import Foundation
@testable import MarkdownCore
import XCTest

final class MarkdownFenceScannerTests: XCTestCase {
    func testOpenFenceRules() {
        for testCase in Self.openFenceCases {
            let (text, location) = Self.unmark(testCase.marked)
            let expected = testCase.expected.map { expected in
                MarkdownFence(
                    marker: expected.marker,
                    length: expected.length,
                    openingLineStart: Self.lineStart(of: expected.openingLine, in: text)
                )
            }

            for (variant, fence) in Self.allEncodings(of: text, { units in
                MarkdownFenceScanner.openFence(in: units, before: location, indentation: testCase.indentation)
            }, string: { source in
                MarkdownFenceScanner.openFence(in: source, before: location, indentation: testCase.indentation)
            }) {
                XCTAssertEqual(fence, expected, "\(testCase.name) [\(variant)]")
            }
        }
    }

    func testOpenFenceClampsOutOfRangeLocations() {
        let text = "```\ncode"
        XCTAssertNil(MarkdownFenceScanner.openFence(in: text, before: 0))
        XCTAssertNil(MarkdownFenceScanner.openFence(in: text, before: -5))
        XCTAssertNil(MarkdownFenceScanner.openFence(in: "", before: 3))
        XCTAssertEqual(
            MarkdownFenceScanner.openFence(in: text, before: 10000),
            MarkdownFence(marker: .backtick, length: 3, openingLineStart: 0)
        )
    }

    func testLocationInsideSurrogatePairCountsItsLine() {
        // `😀` occupies UTF-16 offsets 4 and 5; offset 5 splits the pair.
        let text = "```\n😀\n```\nafter"
        for (variant, fence) in Self.allEncodings(of: text, { units in
            MarkdownFenceScanner.openFence(in: units, before: 5, indentation: .commonMark)
        }, string: { source in
            MarkdownFenceScanner.openFence(in: source, before: 5)
        }) {
            XCTAssertEqual(fence, MarkdownFence(marker: .backtick, length: 3, openingLineStart: 0), variant)
        }
    }

    func testFrontmatterRange() {
        let cases: [String: (text: String, length: Int?)] = [
            "YAML": ("---\ntitle: A\n---\nbody", 17),
            "TOML": ("+++\ntitle = 1\n+++\r\nbody", 19),
            "last line without terminator": ("---\na: 1\n---", 12),
            "unclosed": ("---\ntitle: A\nbody", nil),
            "mismatched marker": ("---\na\n+++\nbody", nil),
            "not on the first line": ("\n---\na\n---\n", nil),
            "four dashes": ("----\na\n----\n", nil),
            "empty": ("", nil),
        ]

        for (name, testCase) in cases {
            let expected = testCase.length.map { NSRange(location: 0, length: $0) }
            XCTAssertEqual(MarkdownFenceScanner.frontmatterRange(in: testCase.text), expected, name)
            Self.withUTF16Units(of: testCase.text) { units in
                XCTAssertEqual(MarkdownFenceScanner.frontmatterRange(in: units), expected, "\(name) [utf16]")
            }
        }
    }

    func testContextRangeExpandsAcrossFencesAndFrontmatter() {
        for testCase in Self.contextCases {
            let source = testCase.text as NSString
            let requested = source.range(of: testCase.requested)
            let expected = source.range(of: testCase.expected)
            XCTAssertNotEqual(requested.location, NSNotFound, testCase.name)
            XCTAssertNotEqual(expected.location, NSNotFound, testCase.name)

            for (variant, range) in Self.allEncodings(of: testCase.text, { units in
                MarkdownFenceScanner.contextRange(in: units, expanding: requested, indentation: .commonMark)
            }, string: { text in
                MarkdownFenceScanner.contextRange(in: text, expanding: requested)
            }) {
                XCTAssertEqual(range, expected, "\(testCase.name) [\(variant)]")
            }
        }
    }

    func testEmptyRequestDoesNotPullInFrontmatter() {
        let text = "---\na: 1\n---\nbody\n"
        let range = MarkdownFenceScanner.contextRange(in: text, expanding: NSRange(location: 4, length: 0))
        XCTAssertEqual(range, NSRange(location: 4, length: 0))
    }
}

extension MarkdownFenceScannerTests {
    struct ExpectedFence {
        let marker: MarkdownFence.Marker
        let length: Int
        /// Text of the opening line, used to find its UTF-16 start.
        let openingLine: String

        init(_ marker: MarkdownFence.Marker, _ length: Int, _ openingLine: String) {
            self.marker = marker
            self.length = length
            self.openingLine = openingLine
        }
    }

    struct OpenFenceCase {
        let name: String
        /// Source with `‸` marking the query location.
        let marked: String
        var indentation: MarkdownFenceScanner.Indentation = .commonMark
        /// `nil` when no fence is open.
        let expected: ExpectedFence?

        init(
            _ name: String,
            _ marked: String,
            indentation: MarkdownFenceScanner.Indentation = .commonMark,
            _ expected: ExpectedFence?
        ) {
            self.name = name
            self.marked = marked
            self.indentation = indentation
            self.expected = expected
        }
    }

    struct ContextCase {
        let name: String
        let text: String
        /// Whole lines whose range is expanded.
        let requested: String
        /// The expected expanded lines.
        let expected: String
    }

    static let openFenceCases: [OpenFenceCase] = [
        OpenFenceCase("plain text", "plain text‸", nil),
        OpenFenceCase("open backtick", "Intro\n```swift\ncode‸", ExpectedFence(.backtick, 3, "```swift")),
        OpenFenceCase("closed backtick", "```swift\ncode\n```\nafter‸", nil),
        OpenFenceCase("caret on opening line", "```‸", ExpectedFence(.backtick, 3, "```")),
        OpenFenceCase("line at location excluded", "```\ncode\n‸```", ExpectedFence(.backtick, 3, "```")),
        OpenFenceCase(
            "nested shorter fence does not close",
            "````md\n```swift\ninner\n```\nstill‸",
            ExpectedFence(.backtick, 4, "````md")
        ),
        OpenFenceCase("longer run closes", "```\ncode\n`````\nafter‸", nil),
        OpenFenceCase("backticks inside tilde fence", "~~~\n```\nstill tilde‸", ExpectedFence(.tilde, 3, "~~~")),
        OpenFenceCase("tildes inside backtick fence", "```\n~~~\nstill backtick‸", ExpectedFence(.backtick, 3, "```")),
        OpenFenceCase(
            "closing fence with info string does not close",
            "```\ncode\n```js\nstill‸",
            ExpectedFence(.backtick, 3, "```")
        ),
        OpenFenceCase("trailing spaces and tabs still close", "~~~\ncode\n~~~ \t\nafter‸", nil),
        OpenFenceCase("backtick in backtick info string", "```foo`bar\nnot code‸", nil),
        OpenFenceCase("backtick in tilde info string", "~~~ a`b\ncode‸", ExpectedFence(.tilde, 3, "~~~ a`b")),
        OpenFenceCase("two markers are not a fence", "``\ncode‸", nil),
        OpenFenceCase("three spaces of indentation", "   ```\ncode‸", ExpectedFence(.backtick, 3, "   ```")),
        OpenFenceCase("four spaces of indentation", "    ```\ncode‸", nil),
        OpenFenceCase("tab indentation", "\t```\ncode‸", nil),
        OpenFenceCase(
            "list-item fence with any indentation",
            "- item\n    ```swift\n    code‸",
            indentation: .anyWhitespace,
            ExpectedFence(.backtick, 3, "    ```swift")
        ),
        OpenFenceCase(
            "tab-indented fence with any indentation",
            "\t```\ncode‸",
            indentation: .anyWhitespace,
            ExpectedFence(.backtick, 3, "\t```")
        ),
        OpenFenceCase(
            "list-item fence closed with any indentation",
            "- item\n  ```\n  code\n  ```\n‸",
            indentation: .anyWhitespace,
            nil
        ),
        OpenFenceCase("fence inside YAML frontmatter", "---\nnote: |\n  ```\n---\nbody‸", nil),
        OpenFenceCase("fence inside TOML frontmatter", "+++\n```\n+++\nbody‸", nil),
        OpenFenceCase("padded frontmatter markers", "--- \n```\n\t---\nbody‸", nil),
        OpenFenceCase("unclosed frontmatter is not frontmatter", "---\n```\ncode‸", ExpectedFence(.backtick, 3, "```")),
        OpenFenceCase(
            "frontmatter closes only with the same marker",
            "---\n```\n+++\ncode‸",
            ExpectedFence(.backtick, 3, "```")
        ),
        OpenFenceCase("location inside frontmatter", "---\n```‸\n---\nbody", nil),
        OpenFenceCase("CRLF lines", "```\r\ncode\r\n```\r\nafter‸", nil),
        OpenFenceCase("CR lines", "```\rcode\r```\rafter‸", nil),
        OpenFenceCase("open CR fence", "x\r```\rcode‸", ExpectedFence(.backtick, 3, "```")),
        OpenFenceCase(
            "UTF-16 offsets after emoji and CJK",
            "😀 中文上\n😀\n~~~~ 語言\n上😀‸",
            ExpectedFence(.tilde, 4, "~~~~ 語言")
        ),
    ]

    static var contextCases: [ContextCase] {
        let fenced = "Intro\n```swift\nlet a = 1\nlet b = 2\n```\nOutro\n"
        let tilde = "Intro\n~~~\n```\ninside tilde\n~~~\nOutro\n"
        let unclosed = "Intro\n```\nline one\nline two\n"
        let frontmatter = "---\ntitle: A\n---\n```\ncode\n```\n"
        return [
            ContextCase(
                name: "start inside fence",
                text: fenced,
                requested: "let b = 2\n",
                expected: "```swift\nlet a = 1\nlet b = 2\n```\n"
            ),
            ContextCase(
                name: "end inside fence",
                text: fenced,
                requested: "Intro\n```swift\n",
                expected: "Intro\n```swift\nlet a = 1\nlet b = 2\n```\n"
            ),
            ContextCase(name: "outside fence unchanged", text: fenced, requested: "Outro\n", expected: "Outro\n"),
            ContextCase(
                name: "backticks inside tilde fence",
                text: tilde,
                requested: "inside tilde\n",
                expected: "~~~\n```\ninside tilde\n~~~\n"
            ),
            ContextCase(
                name: "unclosed fence runs to the end",
                text: unclosed,
                requested: "line one\n",
                expected: "```\nline one\nline two\n"
            ),
            ContextCase(
                name: "range inside frontmatter",
                text: frontmatter,
                requested: "title: A\n",
                expected: "---\ntitle: A\n---\n"
            ),
            ContextCase(
                name: "range after frontmatter",
                text: frontmatter,
                requested: "code\n",
                expected: "```\ncode\n```\n"
            ),
        ]
    }

    static func unmark(_ marked: String) -> (text: String, location: Int) {
        let range = (marked as NSString).range(of: "‸")
        precondition(range.location != NSNotFound, "missing caret in \(marked)")
        return ((marked as NSString).replacingCharacters(in: range, with: ""), range.location)
    }

    static func lineStart(of line: String, in text: String) -> Int {
        let range = (text as NSString).range(of: line)
        precondition(range.location != NSNotFound, "missing line \(line)")
        return range.location
    }

    static func withUTF16Units<Result>(of text: String, _ body: (MarkdownFenceScanUnits) -> Result) -> Result {
        let units = Array(text.utf16)
        guard !units.isEmpty else {
            return [UInt16(0)].withUnsafeBufferPointer { buffer in
                body(MarkdownFenceScanUnits(utf16: buffer.baseAddress!, count: 0))
            }
        }
        return units.withUnsafeBufferPointer { buffer in
            body(MarkdownFenceScanUnits(utf16: buffer.baseAddress!, count: buffer.count))
        }
    }

    /// Runs one query against a native string, an `NSMutableString` bridged to `String`, and
    /// explicit UTF-16 units, so the UTF-8 and UTF-16 scans must agree. Swift bridges that
    /// `NSMutableString` to native UTF-8 storage; the CoreFoundation in-place and copy paths
    /// are covered with `NSTextStorage` in `EditorKitTests.MarkdownFenceScannerStorageTests`.
    static func allEncodings<Result>(
        of text: String,
        _ units: (MarkdownFenceScanUnits) -> Result,
        string: (String) -> Result
    ) -> [(String, Result)] {
        var native = text
        native.makeContiguousUTF8()
        let bridged = NSMutableString(string: text) as String
        return [
            ("native", string(native)),
            ("bridged", string(bridged)),
            ("utf16", withUTF16Units(of: text, units)),
        ]
    }
}
