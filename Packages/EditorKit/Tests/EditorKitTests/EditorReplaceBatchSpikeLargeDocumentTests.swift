import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
final class EditorReplaceBatchSpikeLargeDocumentTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testMinimalEnclosingRangeOnLargeFixtureNearCeiling() throws {
        let source = try String(
            contentsOf: EditorReplaceBatchSpikeSupport.repoRoot
                .appendingPathComponent("Fixtures/large-1mb.md"),
            encoding: .utf8
        )
        let query = "an"
        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(in: source, query: query)
        XCTAssertGreaterThan(ranges.count, 8000)
        XCTAssertLessThanOrEqual(ranges.count, EditorFindLimits.retainedMatchCeiling)
        XCTAssertFalse(ranges.count > EditorFindLimits.retainedMatchCeiling)

        let replacement = String(repeating: "z", count: 256)
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: source)
        let constructionStart = DispatchTime.now()
        let planned = try XCTUnwrap(EditorReplaceBatchSpike.replacedSource(
            source,
            ranges: ranges,
            replacement: replacement
        ))
        let constructionNS = DispatchTime.now().uptimeNanoseconds - constructionStart.uptimeNanoseconds

        let commitStart = DispatchTime.now()
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(ranges: ranges, replacement: replacement),
            using: .minimalEnclosingRange,
            in: fixture.textView
        )
        let commitNS = DispatchTime.now().uptimeNanoseconds - commitStart.uptimeNanoseconds

        XCTAssertTrue(result.applied)
        XCTAssertEqual(result.nativeEditCount, 1)
        XCTAssertEqual(fixture.model.writerActivations, 1)
        XCTAssertEqual(fixture.model.publications.count, 1)
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), planned)
        XCTAssertEqual(fixture.model.source, planned)

        let typingStart = DispatchTime.now()
        fixture.textView.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        let typingNS = DispatchTime.now().uptimeNanoseconds - typingStart.uptimeNanoseconds
        XCTAssertTrue(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView).hasPrefix("!"))

        print(
            """
            R0 B1 large-1mb.md query=\(query) matches=\(ranges.count) \
            constructionMs=\(Double(constructionNS) / 1_000_000) \
            commitMs=\(Double(commitNS) / 1_000_000) \
            postBatchInsertMs=\(Double(typingNS) / 1_000_000) \
            plannedUTF16=\((planned as NSString).length)
            """
        )
    }
}
