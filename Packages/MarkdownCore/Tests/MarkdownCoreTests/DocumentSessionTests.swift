@testable import MarkdownCore
import XCTest

@MainActor
final class DocumentSessionTests: XCTestCase {
    func testInitialSnapshotReflectsSessionState() {
        let fileURL = URL(fileURLWithPath: "/tmp/post.md")
        let session = DocumentSession(
            text: "Hello world",
            url: fileURL,
            fileKind: .markdown,
            isDirty: false
        )

        XCTAssertEqual(session.text, "Hello world")
        XCTAssertEqual(session.version, 0)
        XCTAssertEqual(session.fileURL, fileURL)
        XCTAssertEqual(session.fileKind, .markdown)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.statistics, TextStatistics(text: "Hello world"))
        XCTAssertEqual(
            session.snapshot,
            DocumentSnapshot(
                text: "Hello world",
                version: 0,
                fileKind: .markdown,
                fileURL: fileURL,
                isDirty: false,
                statistics: TextStatistics(text: "Hello world")
            )
        )
    }

    func testReplaceTextMarksDirtyAndIncrementsVersionOnlyWhenTextChanges() {
        let session = DocumentSession(text: "Draft", fileKind: .markdown)

        session.replaceText("Draft updated")

        XCTAssertEqual(session.text, "Draft updated")
        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.statistics, TextStatistics(text: "Draft updated"))

        session.replaceText("Draft updated")

        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)
    }

    func testReplaceTextCanDeferStatisticsUntilExplicitRefresh() {
        let session = DocumentSession(text: "Initial text", fileKind: .markdown)

        session.replaceText("Initial text with more words", refreshStatistics: false)

        XCTAssertEqual(session.statistics, TextStatistics(text: "Initial text"))

        session.refreshStatistics()

        XCTAssertEqual(session.statistics, TextStatistics(text: "Initial text with more words"))
    }

    func testReplacingTextBackToSavedBaselineClearsDirty() {
        let session = DocumentSession(text: "Saved", fileKind: .markdown)

        session.replaceText("Saved with edits")
        XCTAssertTrue(session.isDirty)

        session.replaceText("Saved")

        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.version, 2)
    }

    func testMarkSavedClearsDirtyWithoutAdvancingVersionForDirtyOnlyChange() {
        let fileURL = URL(fileURLWithPath: "/tmp/post.md")
        let session = DocumentSession(
            text: "Saved text",
            url: fileURL,
            fileKind: .markdown,
            isDirty: true
        )

        session.markSaved(text: "Saved text", url: fileURL)

        XCTAssertEqual(session.version, 0)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.fileURL, fileURL)
        XCTAssertEqual(session.fileKind, .markdown)
    }

    func testMarkSavedUpdatesTextURLFileKindAndVersionWhenRenderableStateChanges() {
        let session = DocumentSession(text: "Draft", fileKind: .markdown)

        session.replaceText("Draft changed")
        session.markSaved(text: "Draft changed", url: URL(fileURLWithPath: "/tmp/post.mdx"))

        XCTAssertEqual(session.text, "Draft changed")
        XCTAssertEqual(session.version, 2)
        XCTAssertEqual(session.fileKind, .mdx)
        XCTAssertEqual(session.fileURL, URL(fileURLWithPath: "/tmp/post.mdx"))
        XCTAssertFalse(session.isDirty)

        session.markSaved(text: "Draft changed", url: URL(fileURLWithPath: "/tmp/post.mdx"))

        XCTAssertEqual(session.version, 2)
    }

    func testResetReplacesStateAndAdvancesVersionOnlyWhenRenderableStateChanges() {
        let session = DocumentSession(
            text: "Old",
            url: URL(fileURLWithPath: "/tmp/old.md"),
            fileKind: .markdown,
            isDirty: true
        )

        session.reset(
            text: "New\nText",
            url: URL(fileURLWithPath: "/tmp/new.mdx"),
            fileKind: .mdx,
            isDirty: false
        )

        XCTAssertEqual(session.text, "New\nText")
        XCTAssertEqual(session.version, 1)
        XCTAssertEqual(session.fileURL, URL(fileURLWithPath: "/tmp/new.mdx"))
        XCTAssertEqual(session.fileKind, .mdx)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.statistics, TextStatistics(text: "New\nText"))

        session.reset(
            text: "New\nText",
            url: URL(fileURLWithPath: "/tmp/new.mdx"),
            fileKind: .mdx,
            isDirty: true
        )

        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)
    }
}
