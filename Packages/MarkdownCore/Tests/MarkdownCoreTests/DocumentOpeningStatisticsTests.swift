@testable import MarkdownCore
import XCTest

@MainActor
final class DocumentOpeningStatisticsTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/open.md")
    private let source = String(repeating: "一份繁體中文文件 👩🏽‍💻\r\n", count: 6000)

    func testSmallOpenHasImmediateCounts() {
        let session = DocumentSession(opening: "small", url: url, fileKind: .markdown)
        XCTAssertEqual(session.availableStatistics, TextStatistics(text: "small"))
    }

    func testLargeOpenCanRelocateBeforeCountsArrive() async {
        let ready = expectation(description: "initial counts published")
        let session = DocumentSession(opening: source, url: url, fileKind: .markdown) { _ in ready.fulfill() }
        XCTAssertNil(session.snapshot.availableStatistics)
        XCTAssertEqual(session.text, source)
        session.relocate(to: url.deletingLastPathComponent().appendingPathComponent("moved.mdx"))
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(session.snapshot.availableStatistics, TextStatistics(text: source))
        XCTAssertEqual(session.fileKind, .mdx)
        XCTAssertEqual(session.version, 1)
        XCTAssertFalse(session.isDirty)
    }

    func testImmediateEditAndSecondOpenKeepIndependentCounts() async {
        let first = DocumentSession(opening: source, url: url, fileKind: .markdown) { _ in
            XCTFail("The cancelled initial count reached the edited session")
        }
        XCTAssertNil(first.availableStatistics)
        first.replaceTextFromAuthorizedEditor("edited", refreshStatistics: false)
        first.applyStatistics(TextStatistics(text: first.text))
        let ready = expectation(description: "second document counted")
        let otherSource = String(source.reversed())
        let second = DocumentSession(opening: otherSource, url: url, fileKind: .markdown) { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(first.availableStatistics, TextStatistics(text: "edited"))
        XCTAssertTrue(first.isDirty)
        XCTAssertEqual(second.availableStatistics, TextStatistics(text: otherSource))
        XCTAssertEqual(second.version, 0)
    }
}
