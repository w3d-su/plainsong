import AppKit
@testable import EditorKit
import XCTest

/// T1 of `docs/table-wysiwyg-gates.md`: the presentation hook reads SyntaxKit table regions,
/// so a table the model leaves raw gets no row marker, and an eligible one gets one per row.
@MainActor
final class WYSIWYGTableModelPresentationTests: XCTestCase {
    private func markedRows(in source: String, width: CGFloat = 640) throws -> [String] {
        let fixture = try WYSIWYGTableSpikeFixture.makeWindowedEditor(
            source: source,
            spikeEnabled: true,
            frame: NSRect(x: 0, y: 0, width: width, height: 360)
        )
        defer { fixture.window.orderOut(nil) }
        let text = source as NSString
        var rows: [String] = []
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            if let marker = fixture.textView.wysiwygTableRowMarker(at: line.location),
               marker.rowRange.location == line.location
            {
                rows.append(text.substring(with: marker.rowRange))
            }
            location = NSMaxRange(line)
        }
        return rows
    }

    func testEveryEligibleTableIsPresentedRowByRow() throws {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |\n\nText\n\nx | y\n--|--\n3 | 4\n"
        XCTAssertEqual(try markedRows(in: source), [
            "| a | b |", "|---|---|", "| 1 | 2 |",
            "x | y", "--|--", "3 | 4",
        ])
    }

    func testTablesTheModelLeavesRawGetNoMarkers() throws {
        let raw = [
            "> | a | b |\n> |---|---|\n> | 1 | 2 |\n",
            "| a | b |\n|---|---|\n| 1 | 2 | 3 |\n",
            "| a | b |\n|---|---|\n1 | 2 |\n",
            "a | b\n:-:|---\n1 | 2\n",
        ]
        for source in raw {
            XCTAssertEqual(try markedRows(in: source), [], source.debugDescription)
        }
    }

    func testTableWiderThanTheTextContainerStaysRaw() throws {
        let wide = "| " + String(repeating: "wide ", count: 40) + "| b |\n|---|---|\n| 1 | 2 |\n"
        XCTAssertEqual(try markedRows(in: wide, width: 320), [])
        XCTAssertEqual(try markedRows(in: wide, width: 2400).count, 3)
    }
}
