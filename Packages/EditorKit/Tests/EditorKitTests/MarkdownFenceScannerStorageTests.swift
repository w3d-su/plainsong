import AppKit
import MarkdownCore
import XCTest

/// `MarkdownFenceScanner` reads a string's contiguous UTF-8 when Swift has it, else the
/// CoreFoundation UTF-16 buffer in place, else one UTF-16 copy. A `String` made with
/// `NSMutableString(string:) as String` is already native UTF-8, so only `NSTextStorage`
/// (what the editor scans) reaches the two CoreFoundation paths. Which one depends on the
/// storage's internal representation (it changes with length), so each fixture records the
/// path it took, every query is compared with native storage, and both paths must be reached.
final class MarkdownFenceScannerStorageTests: XCTestCase {
    private enum ScanPath: Hashable {
        case contiguousUTF8, inPlaceUTF16, copiedUTF16
    }

    private static let documents = [
        "---\ntitle: x\n---\nintro\n```swift\nlet a = 1\n~~~\n```\nafter\n````\nopen",
        "---\r\n標題: 中文\r\n---\r\n前言 😀\r\n```js\r\nconst é = 1\r\n```\r\n  ~~~\r\n內容\r\n~~~~\r\n結尾",
        "\u{FEFF}```\n😀😀\n```\n\r```tsx\n<Card 中=\"文\" />\n",
    ]

    func testTextStorageStringsMatchNativeOnBothCoreFoundationPaths() {
        var reached: Set<ScanPath> = []
        for base in Self.documents {
            // A longer copy changes the storage's representation, and so the path taken.
            for document in [base, String(repeating: base + "\n", count: 16)] {
                let storage = NSTextStorage(string: document)
                for storageText in [storage.string, storage.mutableString as String] {
                    reached.insert(Self.scanPath(of: storageText))
                    assertMatchesNative(storageText, document: document)
                }
            }
        }
        XCTAssertTrue(reached.contains(.inPlaceUTF16), "no fixture reached the in-place UTF-16 path: \(reached)")
        XCTAssertTrue(reached.contains(.copiedUTF16), "no fixture reached the copied UTF-16 path: \(reached)")
    }

    /// The branch `MarkdownFenceScanner.withScanUnits` takes for `text`.
    private static func scanPath(of text: String) -> ScanPath {
        if text.utf8.withContiguousStorageIfAvailable({ _ in true }) == true {
            return .contiguousUTF8
        }
        return CFStringGetCharactersPtr(text as NSString as CFString) == nil ? .copiedUTF16 : .inPlaceUTF16
    }

    private func assertMatchesNative(_ bridged: String, document: String, line: UInt = #line) {
        var native = document
        native.makeContiguousUTF8()
        let length = (document as NSString).length
        XCTAssertEqual(
            MarkdownFenceScanner.frontmatterRange(in: bridged),
            MarkdownFenceScanner.frontmatterRange(in: native),
            line: line
        )
        let nsDocument = document as NSString
        let lineStarts = [0] + (0 ..< length).compactMap { index -> Int? in
            let unit = nsDocument.character(at: index)
            return unit == 0x0A || unit == 0x0D ? index + 1 : nil
        }
        // Every line start and its neighbours, plus evenly spaced offsets (inside surrogate
        // pairs too): linear in the document, so the 16x fixtures stay fast.
        let locations = Set(lineStarts.flatMap { [$0, $0 + 1, max(0, $0 - 1)] })
            .union(stride(from: 0, through: length + 1, by: max(1, length / 64)))
        for indentation in [MarkdownFenceScanner.Indentation.commonMark, .anyWhitespace] {
            for location in locations.sorted() {
                XCTAssertEqual(
                    MarkdownFenceScanner.openFence(in: bridged, before: location, indentation: indentation),
                    MarkdownFenceScanner.openFence(in: native, before: location, indentation: indentation),
                    "openFence before \(location) \(indentation)",
                    line: line
                )
            }
            for (index, start) in lineStarts.enumerated() {
                let ends = [index, index + 1, index + 3, lineStarts.count - 1]
                    .filter { $0 < lineStarts.count }
                    .map { lineStarts[$0] }
                for end in Set(ends) where end >= start {
                    let range = NSRange(location: start, length: end - start)
                    XCTAssertEqual(
                        MarkdownFenceScanner.contextRange(in: bridged, expanding: range, indentation: indentation),
                        MarkdownFenceScanner.contextRange(in: native, expanding: range, indentation: indentation),
                        "contextRange \(range) \(indentation)",
                        line: line
                    )
                }
            }
        }
    }
}
