import Foundation
@testable import MarkdownCore
import XCTest

final class EditorReplaceBatchPreparationTests: XCTestCase {
    func testExactTenThousandBuildsOneMinimalEnclosingSlice() throws {
        let source = "before " + String(repeating: "x ", count: 10000) + "after"
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        let prepared = try prepare(session, source: source, replacement: "z").get()
        XCTAssertEqual(prepared.plan.totalCount, 10000)
        XCTAssertEqual(prepared.plan.changedCount, 10000)
        XCTAssertEqual(prepared.plan.enclosingRange, NSRange(location: 7, length: 19999))
        XCTAssertEqual(prepared.replacementSlice, String(repeating: "z ", count: 9999) + "z")
        XCTAssertTrue(ExactSourceText.matches(
            prepared.expectedSource,
            "before " + String(repeating: "z ", count: 10000) + "after"
        ))
    }

    func testMaximumReplacementGrowthUsesOriginalSetWithoutRecursion() throws {
        let source = String(repeating: "x", count: 10000)
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        let replacement = String(repeating: "x", count: 256)
        let prepared = try prepare(session, source: source, replacement: replacement).get()
        XCTAssertEqual(prepared.plan.changedCount, 10000)
        XCTAssertEqual(prepared.plan.projectedUTF16Length, 2_560_000)
        XCTAssertEqual(prepared.expectedSource.utf16.count, 2_560_000)
        XCTAssertTrue(ExactSourceText.matches(prepared.expectedSource, String(repeating: replacement, count: 10000)))
        XCTAssertEqual(prepared.postSelection, NSRange(location: 256, length: 0))
    }

    func testTenThousandAndOneIsRefusedBeforeConstruction() {
        let source = String(repeating: "x", count: 10001)
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        var chunks: [EditorReplacePreparationChunk] = []
        let result = EditorReplaceBatchPreparation.prepare(
            session: session, source: source, replacement: "z", selection: NSRange(location: 0, length: 1),
            onChunk: { chunks.append($0) }
        )
        XCTAssertEqual(result, .failure(.invalidPlan(.truncatedSession)))
        XCTAssertEqual(chunks.map(\.copiedUTF16Count), [0])
    }

    func testDeterministicCancellationAtSixtyFourPlannedMatches() {
        let source = String(repeating: "x", count: 200)
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        var cancelled = false
        var chunks: [EditorReplacePreparationChunk] = []
        let result = EditorReplaceBatchPreparation.prepare(
            session: session, source: source, replacement: "z", selection: NSRange(location: 0, length: 1),
            isCancelled: { cancelled }, onChunk: { chunk in
                chunks.append(chunk)
                cancelled = chunk.plannedMatchCount == 64
            }
        )
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertEqual(chunks.map(\.plannedMatchCount), [0, 64])
        XCTAssertEqual(chunks.map(\.copiedUTF16Count), [0, 0])
    }

    func testDeterministicCancellationInsideLongCopiedGapAtUTF16Boundary() {
        let source = "x" + String(repeating: "a", count: 200_000) + "x"
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        var cancelled = false
        var copied: [Int] = []
        let result = EditorReplaceBatchPreparation.prepare(
            session: session, source: source, replacement: "z", selection: NSRange(location: 0, length: 1),
            isCancelled: { cancelled }, onChunk: { chunk in
                copied.append(chunk.copiedUTF16Count)
                if chunk.copiedUTF16Count == 65536 {
                    cancelled = true
                }
            }
        )
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertEqual(copied.last, 65536)
        XCTAssertTrue(copied.dropLast().allSatisfy { $0 == 0 })
    }

    func testLongReplacementChecksAfterAtMostSixtyFourConstructedMatches() {
        let source = String(repeating: "x", count: 400)
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        var cancelled = false
        var lastCopy = 0
        let result = EditorReplaceBatchPreparation.prepare(
            session: session, source: source, replacement: String(repeating: "z", count: 256),
            selection: NSRange(location: 0, length: 1), isCancelled: { cancelled }, onChunk: { chunk in
                lastCopy = chunk.copiedUTF16Count
                if lastCopy > 0 {
                    cancelled = true
                }
            }
        )
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertEqual(lastCopy, 64 * 256)
    }

    func testUTF16ConstructionNeverSplitsSurrogatePairsAndBoundsAllCopies() throws {
        // The first copy boundary falls in the emoji's surrogate pair.
        let source = "x" + String(repeating: "a", count: 65534) + "😀" + String(repeating: "b", count: 100_000) + "x"
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        var chunks: [EditorReplacePreparationChunk] = []
        let prepared = try EditorReplaceBatchPreparation.prepare(
            session: session, source: source, replacement: "z", selection: NSRange(location: 0, length: 1),
            onChunk: { chunks.append($0) }
        ).get()
        XCTAssertTrue(ExactSourceText.matches(
            prepared.expectedSource,
            "z" + String(source.dropFirst().dropLast()) + "z"
        ))
        let copied = chunks.map(\.copiedUTF16Count)
        for (previous, next) in zip(copied, copied.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next, previous)
            XCTAssertLessThanOrEqual(next - previous, 65536)
        }
        XCTAssertGreaterThan(copied.last ?? 0, (source as NSString).length)
    }

    func testFullExpectedSourcePrefixAndSuffixAlsoObserveCopyCheckpoints() {
        let source = String(repeating: "a", count: 200_000) + "x" + String(repeating: "b", count: 200_000)
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        var cancelled = false
        var lastCopy = 0
        let result = EditorReplaceBatchPreparation.prepare(
            session: session, source: source, replacement: "z", selection: NSRange(location: 200_000, length: 1),
            isCancelled: { cancelled }, onChunk: { chunk in
                lastCopy = chunk.copiedUTF16Count
                if lastCopy == 65537 {
                    cancelled = true
                }
            }
        )
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertEqual(lastCopy, 65537) // One-unit B1 slice + first full-source copy chunk.
    }

    func testAtMostOneHundredStrictlyMonotonicProgressValuesEndsAfterConstruction() throws {
        let source = String(repeating: "x", count: 10000)
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        var progress: [EditorReplacePreparationProgress] = []
        var copiedAtCompletion = 0
        var lastCopied = 0
        _ = try EditorReplaceBatchPreparation.prepare(
            session: session, source: source, replacement: "z", selection: NSRange(location: 0, length: 1),
            onChunk: { lastCopied = $0.copiedUTF16Count }, progress: { value in
                progress.append(value)
                if value.completedMatchCount == value.totalMatchCount {
                    copiedAtCompletion = lastCopied
                }
            }
        ).get()
        XCTAssertEqual(progress.count, 100)
        XCTAssertEqual(progress.map(\.completedMatchCount), Array(stride(from: 100, through: 10000, by: 100)))
        XCTAssertTrue(progress.allSatisfy { $0.totalMatchCount == 10000 })
        XCTAssertEqual(copiedAtCompletion, 20000)
    }

    func testNoChangesPreservesSelectionAndDoesNotCopyOrConstruct() throws {
        let source = "x x x"
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        let selection = NSRange(location: 2, length: 1)
        var copied: [Int] = []
        let prepared = try EditorReplaceBatchPreparation.prepare(
            session: session, source: source, replacement: "x", selection: selection,
            onChunk: { copied.append($0.copiedUTF16Count) }
        ).get()
        XCTAssertTrue(prepared.plan.isNoOp)
        XCTAssertNil(prepared.replacementSlice)
        XCTAssertTrue(ExactSourceText.matches(prepared.expectedSource, source))
        XCTAssertEqual(prepared.postSelection, selection)
        XCTAssertTrue(copied.allSatisfy { $0 == 0 })
    }

    func testMixedCanonicalEquivalentAndUnequalLengthsUseExactRetainedRanges() throws {
        let source = "é e\u{0301} é"
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "é"), preferredOrdinal: 2)
        let prepared = try prepare(session, source: source, replacement: "é").get()
        XCTAssertEqual(
            prepared.plan,
            try EditorReplacePlanner.planBatch(session: session, source: source, replacement: "é").get()
        )
        XCTAssertEqual(prepared.plan.changedCount, 1)
        XCTAssertEqual(prepared.plan.totalCount, 3)
        XCTAssertEqual(prepared.plan.enclosingRange, NSRange(location: 2, length: 2))
        XCTAssertEqual(prepared.replacementSlice, "é")
        XCTAssertTrue(ExactSourceText.matches(prepared.expectedSource, "é é é"))
        XCTAssertEqual(prepared.postSelection, NSRange(location: 3, length: 0))
    }

    func testCurrentTrailingBoundaryDoesNotConsumeAdjacentNextReplacement() throws {
        let source = "xx"
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        let prepared = try prepare(session, source: source, replacement: "xxx").get()
        XCTAssertEqual(prepared.expectedSource, "xxxxxx")
        XCTAssertEqual(prepared.postSelection, NSRange(location: 3, length: 0))
    }

    func testUnresolvedCurrentMapsCaretAndDeletionRemainsValid() throws {
        let source = "x ab x"
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
            .withUnresolvedCurrent(caretAnchorUTF16: 4)
        let prepared = try EditorReplaceBatchPreparation.prepare(
            session: session, source: source, replacement: "", selection: NSRange(location: 4, length: 0)
        ).get()
        XCTAssertEqual(prepared.expectedSource, " ab ")
        XCTAssertEqual(prepared.postSelection, NSRange(location: 3, length: 0))
    }

    func testMalformedNegativeOverflowOverlapOutOfBoundsZeroAndSurrogateRangesRefuse() {
        let invalidRangeSets: [[NSRange]] = [
            [NSRange(location: -1, length: 1)], [NSRange(location: 0, length: -1)],
            [NSRange(location: Int.max, length: 1)], [NSRange(location: 0, length: 0)],
            [NSRange(location: 0, length: 3), NSRange(location: 2, length: 1)],
            [NSRange(location: 2, length: 1), NSRange(location: 0, length: 2)],
            [NSRange(location: 4, length: 1)], [NSRange(location: 1, length: 1)],
        ]
        for ranges in invalidRangeSets {
            let session = EditorFindSession(engineResults: ranges.map(match), query: TextSearchQuery(pattern: "x"))
            XCTAssertEqual(
                prepare(session, source: "😀xx", replacement: "z"),
                .failure(.invalidPlan(.noCurrentMatch)),
                "\(ranges)"
            )
        }
    }

    func testInvalidReplacementAndEmptySessionRefuseBeforeOutputAllocation() {
        let source = "x"
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "x"))
        XCTAssertEqual(
            prepare(session, source: source, replacement: "\n"),
            .failure(.invalidPlan(.invalidReplacement(.containsNewline)))
        )
        XCTAssertEqual(
            prepare(session, source: source, replacement: String(repeating: "x", count: 257)),
            .failure(.invalidPlan(.invalidReplacement(.exceedsMaximumUTF16Length)))
        )
        XCTAssertEqual(
            prepare(.empty(query: TextSearchQuery(pattern: "x")), source: source, replacement: "z"),
            .failure(.invalidPlan(.emptySession))
        )
        XCTAssertNil(EditorReplaceSourceConstruction.projectedUTF16Length(
            sourceLength: Int.max,
            ranges: [NSRange(location: 0, length: 1)],
            replacementUTF16Length: 256
        ))
    }

    private func prepare(_ session: EditorFindSession, source: String,
                         replacement: String)
        -> Result<EditorReplacePreparedBatch, EditorReplaceBatchPreparationFailure>
    {
        EditorReplaceBatchPreparation.prepare(
            session: session, source: source, replacement: replacement,
            selection: session.currentMatch?.range ?? NSRange(location: session.caretAnchorUTF16, length: 0)
        )
    }

    private func match(_ range: NSRange) -> TextSearchMatch {
        TextSearchMatch(range: range, line: 1, preview: "", previewMatchRange: NSRange(location: 0, length: 0))
    }
}
