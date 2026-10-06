import Foundation
@testable import MarkdownCore
import XCTest

/// Checkpointed preparation duplicates the reference builders to bound cancellation.
/// Keep the two implementations aligned, including literal UTF-16 and caret mapping.
final class EditorReplaceBatchDifferentialTests: XCTestCase {
    func testFixedSeedUnicodeCaseAndWholeWordPreparationMatchesReferenceBuilders() throws {
        var random = BatchRandom(seed: 0x19_A59D_E63D)
        let atoms = ["hit", "HIT", "Hit", "é", "e\u{301}", "😀", "𐐀", "中文", " ", "_", "-", "x"]
        let patterns = ["hit", "é", "😀", "𐐀", "中文", "x"]
        let replacements = ["", "hit", "HIT", "é", "e\u{301}", "😀é", "中文", "hit hit"]
        for index in 0 ..< 2000 {
            let source = (0 ..< 12 + random.next(90)).map { _ in atoms[random.next(atoms.count)] }.joined()
            let query = TextSearchQuery(
                pattern: patterns[random.next(patterns.count)],
                caseSensitivity: index % 3 == 0 ? .sensitive : index % 3 == 1 ? .insensitive : .smart,
                wholeWord: index % 2 == 0
            )
            var session = EditorFindSession.search(in: source, query: query)
            guard session.total > 0 else { continue }
            let anchor = random.next(source.utf16.count + 1)
            session = index % 3 == 0
                ? session.withUnresolvedCurrent(caretAnchorUTF16: anchor)
                : session.withCurrentOrdinal(random.next(session.total) + 1, caretAnchorUTF16: anchor)
            try assertMatchesReference(
                session, source: source, replacement: replacements[random.next(replacements.count)],
                selection: NSRange(location: anchor, length: 0)
            )
        }
    }

    func testSurrogateHeavyConstructionCrossesEveryChunkBoundaryWithoutDifferentialMismatch() throws {
        for index in 0 ..< 33 {
            let padding = String(repeating: "😀e\u{301}𐐀", count: 11000 + index)
            let source = padding + "hit é e\u{301} hit" + padding
            let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "é"))
            // The source contains more than the ceiling; focus the query on the two hits.
            let hits = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "hit"))
            XCTAssertTrue(session.isTruncated)
            try assertMatchesReference(
                hits, source: source, replacement: index % 2 == 0 ? "😀𐐀" : "hit",
                selection: NSRange(location: source.utf16.count - index, length: 0)
            )
        }
    }

    private func assertMatchesReference(
        _ session: EditorFindSession, source: String, replacement: String, selection: NSRange
    ) throws {
        let reference = try EditorReplacePlanner.planBatch(session: session, source: source, replacement: replacement)
            .get()
        let prepared = try EditorReplaceBatchPreparation.prepare(
            session: session, source: source, replacement: replacement, selection: selection
        ).get()
        XCTAssertEqual(prepared.plan, reference)
        if reference.isNoOp {
            XCTAssertNil(prepared.replacementSlice)
            XCTAssertTrue(ExactSourceText.matches(prepared.expectedSource, source))
            XCTAssertEqual(prepared.postSelection, selection)
            return
        }
        let enclosing = try XCTUnwrap(reference.enclosingRange)
        let slice = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSlice(
            source, enclosing: enclosing, ranges: reference.differingRanges, replacement: replacement
        ))
        let expected = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
            source, ranges: reference.differingRanges, replacement: replacement
        ))
        XCTAssertTrue(try ExactSourceText.matches(XCTUnwrap(prepared.replacementSlice), slice))
        XCTAssertTrue(ExactSourceText.matches(prepared.expectedSource, expected))
        let continuation = EditorReplaceContinuationPlanning.afterBatch(
            plan: reference, preWriteCurrentMatch: session.currentMatch,
            preWriteCaretUTF16: selection.location, postWriteSource: expected
        )
        XCTAssertEqual(prepared.postSelection, continuation.collapsedSelection)
    }
}

private struct BatchRandom {
    var seed: UInt64

    mutating func next(_ limit: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 32) % UInt64(limit))
    }
}
