import AppKit
@testable import EditorKit
import XCTest

@MainActor
final class EditorReplaceBatchSpikeTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testAuthorizationRefusalOpensNoWriterOrUndo() throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: "one two one")
        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(in: fixture.model.source, query: "one")
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(
                ranges: ranges,
                replacement: "ONE",
                isAuthorized: false
            ),
            using: .minimalEnclosingRange,
            in: fixture.textView
        )

        XCTAssertFalse(result.applied)
        XCTAssertEqual(result.nativeEditCount, 0)
        XCTAssertEqual(fixture.model.writerActivations, 0)
        XCTAssertTrue(fixture.model.publications.isEmpty)
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "one two one")
        XCTAssertFalse(fixture.textView.undoManager?.canUndo == true)
        XCTAssertFalse(fixture.model.isDirty)
    }

    func testInvalidRangesOpenNoWriterOrUndo() throws {
        let source = "one two one"
        let overlapping = [
            NSRange(location: 0, length: 5),
            NSRange(location: 3, length: 4),
        ]
        XCTAssertNil(
            EditorReplaceBatchSpike.replacedSource(
                source,
                ranges: overlapping,
                replacement: "ONE"
            )
        )

        for mechanism in [
            EditorReplaceBatchMechanism.minimalEnclosingRange,
            .fullDocument,
            .reverseOrderedNativeEdits,
        ] {
            let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: source)
            let result = fixture.coordinator.performReplaceBatchSpike(
                EditorReplaceBatchRequest(ranges: overlapping, replacement: "ONE"),
                using: mechanism,
                in: fixture.textView
            )

            XCTAssertFalse(result.applied, "\(mechanism)")
            XCTAssertEqual(result.nativeEditCount, 0, "\(mechanism)")
            XCTAssertEqual(fixture.model.writerActivations, 0, "\(mechanism)")
            XCTAssertTrue(fixture.model.publications.isEmpty, "\(mechanism)")
            XCTAssertEqual(
                EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView),
                source,
                "\(mechanism)"
            )
            XCTAssertFalse(fixture.textView.undoManager?.canUndo == true, "\(mechanism)")
            XCTAssertFalse(fixture.model.isDirty, "\(mechanism)")
        }
    }

    func testCandidateAPublishesOncePerMatch() throws {
        let outcome = try runSmallBatch(using: .reverseOrderedNativeEdits)
        XCTAssertTrue(outcome.result.applied)
        XCTAssertEqual(outcome.result.nativeEditCount, 2)
        XCTAssertEqual(outcome.fixture.model.writerActivations, 1)
        XCTAssertEqual(outcome.fixture.model.publications.count, 2)
        XCTAssertEqual(outcome.view, "ONE two ONE")
    }

    func testCandidateB1PublishesOnceForTheEnclosingRange() throws {
        let outcome = try runSmallBatch(using: .minimalEnclosingRange)
        XCTAssertTrue(outcome.result.applied)
        XCTAssertEqual(outcome.result.nativeEditCount, 1)
        XCTAssertEqual(outcome.fixture.model.writerActivations, 1)
        XCTAssertEqual(outcome.fixture.model.publications.count, 1)
        XCTAssertEqual(outcome.view, "ONE two ONE")
        XCTAssertEqual(outcome.fixture.model.publications[0], "ONE two ONE")
    }

    func testCandidateB2PublishesOnceForTheFullDocument() throws {
        let outcome = try runSmallBatch(using: .fullDocument)
        XCTAssertTrue(outcome.result.applied)
        XCTAssertEqual(outcome.result.nativeEditCount, 1)
        XCTAssertEqual(outcome.fixture.model.writerActivations, 1)
        XCTAssertEqual(outcome.fixture.model.publications.count, 1)
        XCTAssertEqual(outcome.view, "ONE two ONE")
    }

    func testDeletionAndUnequalLengths() throws {
        let source = "one two one"
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: source)
        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(in: source, query: "one")
        XCTAssertEqual(ranges.count, 2)
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(ranges: ranges, replacement: ""),
            using: .minimalEnclosingRange,
            in: fixture.textView
        )
        XCTAssertTrue(result.applied)
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), " two ")
        XCTAssertEqual(fixture.model.publications.count, 1)
    }

    func testReplacementContainingTheQueryIsNotRescannedInTheBatch() throws {
        let source = "a b a"
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: source)
        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(in: source, query: "a")
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(ranges: ranges, replacement: "aa"),
            using: .minimalEnclosingRange,
            in: fixture.textView
        )
        XCTAssertTrue(result.applied)
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "aa b aa")
        XCTAssertEqual(fixture.model.publications.count, 1)
    }

    func testTwoHundredFiftySixCodeUnitReplacement() throws {
        let replacement = String(repeating: "z", count: 256)
        let source = "hit mid hit"
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: source)
        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(in: source, query: "hit")
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(ranges: ranges, replacement: replacement),
            using: .minimalEnclosingRange,
            in: fixture.textView
        )
        XCTAssertTrue(result.applied)
        let expected = "\(replacement) mid \(replacement)"
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), expected)
        XCTAssertEqual((expected as NSString).length, 256 + 5 + 256)
    }

    func testCanonicalEquivalentMatchLengthComesFromTheEngineRange() throws {
        let composed = "café"
        let decomposed = "cafe\u{0301}"
        let source = "\(composed) \(decomposed) \(composed)"
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: source)
        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(
            in: source,
            query: composed,
            caseSensitivity: .insensitive
        )
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertTrue(ranges.contains { $0.length != (composed as NSString).length })
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(ranges: ranges, replacement: "X"),
            using: .minimalEnclosingRange,
            in: fixture.textView
        )
        XCTAssertTrue(result.applied)
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "X X X")
    }

    private struct Outcome {
        let fixture: EditorReplaceBatchSpikeSupport.Fixture
        let result: EditorReplaceBatchResult
        let view: String
    }

    private func runSmallBatch(
        using mechanism: EditorReplaceBatchMechanism
    ) throws -> Outcome {
        let source = "one two one"
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: source)
        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(in: source, query: "one")
        XCTAssertEqual(ranges.count, 2)
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(ranges: ranges, replacement: "ONE"),
            using: mechanism,
            in: fixture.textView
        )
        return Outcome(
            fixture: fixture,
            result: result,
            view: EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView)
        )
    }
}
