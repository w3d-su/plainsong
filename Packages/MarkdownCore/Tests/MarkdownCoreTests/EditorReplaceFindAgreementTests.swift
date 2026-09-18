import Foundation
@testable import MarkdownCore
import XCTest

final class EditorReplaceFindAgreementTests: XCTestCase {
    private struct AgreementCase {
        let name: String
        let source: String
        let query: TextSearchQuery
        let expectedStarts: [Int]
    }

    private static let nfc = "é"
    private static let nfd = "e\u{0301}"
    private static let agreementCases: [AgreementCase] = [
        AgreementCase(
            name: "smart-lowercase-insensitive",
            source: "Cat cat CAT",
            query: TextSearchQuery(pattern: "cat", caseSensitivity: .smart),
            expectedStarts: [0, 4, 8]
        ),
        AgreementCase(
            name: "smart-cased-sensitive",
            source: "Cat cat CAT",
            query: TextSearchQuery(pattern: "Cat", caseSensitivity: .smart),
            expectedStarts: [0]
        ),
        AgreementCase(
            name: "sensitive",
            source: "Cat cat CAT",
            query: TextSearchQuery(pattern: "cat", caseSensitivity: .sensitive),
            expectedStarts: [4]
        ),
        AgreementCase(
            name: "insensitive",
            source: "Cat cat CAT",
            query: TextSearchQuery(pattern: "cat", caseSensitivity: .insensitive),
            expectedStarts: [0, 4, 8]
        ),
        AgreementCase(
            name: "whole-word",
            source: "cat catalog cat",
            query: TextSearchQuery(pattern: "cat", wholeWord: true),
            expectedStarts: [0, 12]
        ),
        AgreementCase(
            name: "canonical-equivalence",
            source: "\(nfc) \(nfd)",
            query: TextSearchQuery(pattern: nfc, caseSensitivity: .insensitive),
            expectedStarts: [0, (nfc as NSString).length + 1]
        ),
        AgreementCase(
            name: "non-overlap",
            source: "aaa",
            query: TextSearchQuery(pattern: "aa"),
            expectedStarts: [0]
        ),
        AgreementCase(
            name: "literal-dot-is-not-regex",
            source: "a.b axb a.b",
            query: TextSearchQuery(pattern: "a.b"),
            expectedStarts: [0, 8]
        ),
    ]

    func testPlannerConsumesExactFindSessionRanges() throws {
        for item in Self.agreementCases {
            let session = EditorFindSession.search(in: item.source, query: item.query)
            XCTAssertEqual(
                session.matches.map(\.range.location),
                item.expectedStarts,
                item.name
            )
            let plan = try EditorReplacePlanner.planBatch(
                session: session,
                source: item.source,
                replacement: "X"
            ).get()
            XCTAssertEqual(plan.allRanges, session.matches.map(\.range), item.name)
            XCTAssertEqual(plan.totalCount, session.total, item.name)
            XCTAssertEqual(plan.changedCount, session.total, item.name)
        }
    }

    func testInvalidFindQueriesProduceEmptySessionRefusal() {
        let source = "hello world"
        let queries = [
            TextSearchQuery(pattern: ""),
            TextSearchQuery(pattern: "a\nb"),
            TextSearchQuery(pattern: String(
                repeating: "q",
                count: TextSearchEngine.maximumPatternUTF16Length + 1
            )),
        ]
        for query in queries {
            let session = EditorFindSession.search(in: source, query: query)
            XCTAssertEqual(session.total, 0, query.pattern)
            XCTAssertEqual(
                EditorReplacePlanner.planOneMatch(
                    session: session,
                    source: source,
                    replacement: "X"
                ),
                .failure(.emptySession),
                query.pattern
            )
            XCTAssertEqual(
                EditorReplacePlanner.planBatch(
                    session: session,
                    source: source,
                    replacement: "X"
                ),
                .failure(.emptySession),
                query.pattern
            )
        }
    }

    func testBatchUsesEntireSessionNotASelection() throws {
        let source = "one two one three one"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "one")
        )
        XCTAssertEqual(session.total, 3)
        let plan = try EditorReplacePlanner.planBatch(
            session: session,
            source: source,
            replacement: "X"
        ).get()
        XCTAssertEqual(plan.allRanges.map(\.location), [0, 8, 18])
        XCTAssertEqual(plan.enclosingRange, NSRange(location: 0, length: 21))
    }
}
