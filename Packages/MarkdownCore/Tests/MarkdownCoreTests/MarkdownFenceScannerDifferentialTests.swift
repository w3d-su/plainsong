import Foundation
@testable import MarkdownCore
import XCTest

/// Compares `MarkdownFenceScanner` with a line-array reference written for clarity, over
/// seeded random documents mixing fences, frontmatter, CJK, emoji and all three line
/// terminators, on native, bridged and UTF-16 storage.
final class MarkdownFenceScannerDifferentialTests: XCTestCase {
    func testScannerMatchesReferenceOnRandomDocuments() {
        var generator = SeededGenerator(seed: 0x5EED_FE4C)
        for documentIndex in 0 ..< 400 {
            let document = DifferentialDocument(text: Self.randomDocument(using: &generator), index: documentIndex)
            let length = (document.text as NSString).length

            for indentation in [MarkdownFenceScanner.Indentation.commonMark, .anyWhitespace] {
                for _ in 0 ..< 6 {
                    document.checkOpenFence(
                        before: Int.random(in: 0 ... length + 1, using: &generator),
                        indentation: indentation
                    )
                }

                let lineCount = document.reference.lines.count
                for _ in 0 ..< 4 where lineCount > 0 {
                    let first = Int.random(in: 0 ..< lineCount, using: &generator)
                    let last = Int.random(in: first ..< lineCount, using: &generator)
                    document.checkContextRange(firstLine: first, lastLine: last, indentation: indentation)
                }
            }

            XCTAssertEqual(
                MarkdownFenceScanner.frontmatterRange(in: document.native),
                document.reference.frontmatterLength.map { NSRange(location: 0, length: $0) },
                "frontmatter document \(documentIndex) in \(document.text.debugDescription)"
            )
        }
    }
}

/// One random document in every storage the scanner accepts.
private struct DifferentialDocument {
    let text: String
    let index: Int
    let native: String
    let bridged: String
    let reference: ReferenceFenceModel

    init(text: String, index: Int) {
        self.text = text
        self.index = index
        var native = text
        native.makeContiguousUTF8()
        self.native = native
        bridged = NSMutableString(string: text) as String
        reference = ReferenceFenceModel(text: text)
    }

    func checkOpenFence(before location: Int, indentation: MarkdownFenceScanner.Indentation) {
        let expected = reference.openFence(before: location, indentation: indentation)
        let context = "document \(index) location \(location) \(indentation) in \(text.debugDescription)"
        XCTAssertEqual(
            MarkdownFenceScanner.openFence(in: native, before: location, indentation: indentation),
            expected,
            "native \(context)"
        )
        XCTAssertEqual(
            MarkdownFenceScanner.openFence(in: bridged, before: location, indentation: indentation),
            expected,
            "bridged \(context)"
        )
        MarkdownFenceScannerTests.withUTF16Units(of: text) { units in
            XCTAssertEqual(
                MarkdownFenceScanner.openFence(in: units, before: location, indentation: indentation),
                expected,
                "utf16 \(context)"
            )
        }
    }

    func checkContextRange(firstLine: Int, lastLine: Int, indentation: MarkdownFenceScanner.Indentation) {
        let start = reference.lines[firstLine].start
        let requested = NSRange(location: start, length: reference.lines[lastLine].fullEnd - start)
        let expected = reference.contextRange(expanding: requested, indentation: indentation)
        let context = "document \(index) range \(requested) \(indentation) in \(text.debugDescription)"
        XCTAssertEqual(
            MarkdownFenceScanner.contextRange(in: native, expanding: requested, indentation: indentation),
            expected,
            "native \(context)"
        )
        XCTAssertEqual(
            MarkdownFenceScanner.contextRange(in: bridged, expanding: requested, indentation: indentation),
            expected,
            "bridged \(context)"
        )
        MarkdownFenceScannerTests.withUTF16Units(of: text) { units in
            XCTAssertEqual(
                MarkdownFenceScanner.contextRange(in: units, expanding: requested, indentation: indentation),
                expected,
                "utf16 \(context)"
            )
        }
    }
}

private extension MarkdownFenceScannerDifferentialTests {
    static let lineVocabulary = [
        "```", "```swift", "````", "`````", "```js`x", "``", "~~~", "~~~~", "~~~ a`b", "```  ",
        "   ```", "    ```", "\t```", "  ~~~", "``` info", "~~~~~~", "---", "+++", " --- ",
        "", "plain prose", "中文段落上", "😀 emoji", "- item", "  - nested", "| a | b |",
        "code();", "上😀```", "`inline`", "~~", "\t", "  ",
    ]
    static let terminators = ["\n", "\n", "\n", "\r\n", "\r"]

    static func randomDocument(using generator: inout SeededGenerator) -> String {
        let lineCount = Int.random(in: 0 ... 14, using: &generator)
        var text = ""
        for index in 0 ..< lineCount {
            text += lineVocabulary.randomElement(using: &generator)!
            if index < lineCount - 1 || Bool.random(using: &generator) {
                text += terminators.randomElement(using: &generator)!
            }
        }
        return text
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// A deliberately naive model of the scanner's rules over an array of lines.
struct ReferenceFenceModel {
    struct Line {
        let start: Int
        let fullEnd: Int
        let scalars: [Unicode.Scalar]
    }

    struct FenceLine {
        let marker: Unicode.Scalar
        let length: Int
        let restIsBlank: Bool
        let restHasBacktick: Bool
    }

    let lines: [Line]
    let utf16Length: Int
    let frontmatterLineCount: Int
    let frontmatterLength: Int?

    init(text: String) {
        let units = Array(text.utf16)
        var lines: [Line] = []
        var start = 0
        var index = 0
        while index < units.count {
            if units[index] == 10 || units[index] == 13 {
                let contentEnd = index
                index += units[index] == 13 && index + 1 < units.count && units[index + 1] == 10 ? 2 : 1
                lines.append(Self.line(units, start, contentEnd, index))
                start = index
            } else {
                index += 1
            }
        }
        if start < units.count {
            lines.append(Self.line(units, start, units.count, units.count))
        }
        self.lines = lines
        utf16Length = units.count

        var frontmatterLineCount = 0
        if let first = lines.first, let marker = Self.frontmatterMarker(first.scalars) {
            for (offset, line) in lines.enumerated().dropFirst() where Self.frontmatterMarker(line.scalars) == marker {
                frontmatterLineCount = offset + 1
                break
            }
        }
        self.frontmatterLineCount = frontmatterLineCount
        frontmatterLength = frontmatterLineCount > 0 ? lines[frontmatterLineCount - 1].fullEnd : nil
    }

    func openFence(before location: Int, indentation: MarkdownFenceScanner.Indentation) -> MarkdownFence? {
        var state = State()
        for line in lines.dropFirst(frontmatterLineCount) where line.start < location {
            _ = state.consume(line, indentation: indentation)
        }
        return state.open
    }

    func contextRange(expanding range: NSRange, indentation: MarkdownFenceScanner.Indentation) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        if let frontmatterLength, range.length > 0, start < frontmatterLength {
            start = 0
            end = max(end, frontmatterLength)
        }

        var state = State()
        var remaining = lines.dropFirst(frontmatterLineCount)[...]
        while let line = remaining.first, line.start < start {
            _ = state.consume(line, indentation: indentation)
            remaining = remaining.dropFirst()
        }
        if let open = state.open {
            start = open.openingLineStart
        }
        while let line = remaining.first, line.start < end {
            _ = state.consume(line, indentation: indentation)
            remaining = remaining.dropFirst()
        }
        if state.open != nil {
            var closingEnd = utf16Length
            for line in remaining where state.consume(line, indentation: indentation) {
                closingEnd = line.fullEnd
                break
            }
            end = max(end, closingEnd)
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    struct State {
        var open: MarkdownFence?

        mutating func consume(_ line: Line, indentation: MarkdownFenceScanner.Indentation) -> Bool {
            guard let fence = ReferenceFenceModel.fenceLine(line.scalars, indentation: indentation) else {
                return false
            }
            let marker: MarkdownFence.Marker = fence.marker == "`" ? .backtick : .tilde
            if let current = open {
                if marker == current.marker, fence.length >= current.length, fence.restIsBlank {
                    open = nil
                    return true
                }
                return false
            }
            if marker == .tilde || !fence.restHasBacktick {
                open = MarkdownFence(marker: marker, length: fence.length, openingLineStart: line.start)
            }
            return false
        }
    }

    static func line(_ units: [UInt16], _ start: Int, _ contentEnd: Int, _ fullEnd: Int) -> Line {
        let content = String(decoding: units[start ..< contentEnd], as: UTF16.self)
        return Line(start: start, fullEnd: fullEnd, scalars: Array(content.unicodeScalars))
    }

    static func fenceLine(_ scalars: [Unicode.Scalar], indentation: MarkdownFenceScanner.Indentation) -> FenceLine? {
        let indent = scalars.prefix { $0 == " " || $0 == "\t" }
        switch indentation {
        case .commonMark:
            guard !indent.contains("\t"), indent.count <= 3 else { return nil }
        case .anyWhitespace:
            break
        }
        let body = scalars.dropFirst(indent.count)
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let run = body.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        let rest = body.dropFirst(run.count)
        return FenceLine(
            marker: marker,
            length: run.count,
            restIsBlank: rest.allSatisfy { $0 == " " || $0 == "\t" },
            restHasBacktick: rest.contains("`")
        )
    }

    static func frontmatterMarker(_ scalars: [Unicode.Scalar]) -> String? {
        let trimmed = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return trimmed == "---" || trimmed == "+++" ? trimmed : nil
    }
}
