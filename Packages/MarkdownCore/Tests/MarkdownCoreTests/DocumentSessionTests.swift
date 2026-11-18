@testable import MarkdownCore
import XCTest

@MainActor
final class DocumentSessionTests: XCTestCase {
    @MainActor
    func testAuthorizedEditorExactNoOpPreservesVersionAndCleanState() {
        let session = DocumentSession(text: "saved", fileKind: .markdown)

        session.replaceTextFromAuthorizedEditor("saved")

        XCTAssertEqual(session.text, "saved")
        XCTAssertEqual(session.version, 0)
        XCTAssertFalse(session.isDirty)
    }

    @MainActor
    func testAuthorizedEditorUndoToPersistedBaselineRestoresCleanState() {
        let session = DocumentSession(text: "saved", fileKind: .markdown)

        session.replaceTextFromAuthorizedEditor("draft")
        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)

        session.replaceTextFromAuthorizedEditor("saved")

        XCTAssertEqual(session.text, "saved")
        XCTAssertEqual(session.version, 2)
        XCTAssertFalse(session.isDirty)
    }

    func testExactSourceTextMatchesOnlyLiteralCodeUnitIdentity() {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"

        XCTAssertTrue(composed == decomposed)
        XCTAssertTrue(ExactSourceText.matches(composed, composed))
        XCTAssertFalse(ExactSourceText.matches(composed, decomposed))
        XCTAssertTrue(ExactSourceText.matches("\u{1F9EA}\0", "\u{1F9EA}\0"))
        XCTAssertFalse(ExactSourceText.matches("line\r\n", "line\n"))
    }

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

    func testCanonicalEquivalentRawDifferentTextPropagatesVersionDirtyStateAndTextChange() async throws {
        let savedText = "cafe\u{0301}"
        let editedText = "caf\u{00E9}"
        let session = DocumentSession(text: savedText, fileKind: .markdown)
        var iterator = session.textChanges(includeCurrent: false).makeAsyncIterator()

        session.replaceText(editedText)

        let nextChange = await iterator.next()
        let change = try XCTUnwrap(nextChange)
        XCTAssertEqual(Array(session.text.utf16), Array(editedText.utf16))
        XCTAssertEqual(Array(change.text.utf16), Array(editedText.utf16))
        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)

        session.replaceText(savedText)

        XCTAssertEqual(Array(session.text.utf16), Array(savedText.utf16))
        XCTAssertEqual(session.version, 2)
        XCTAssertFalse(session.isDirty)
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

    func testRebaseSavedTextPreservesCurrentTextAndUsesExactBytesForDirtyState() {
        let diskA = "cafe\u{0301}"
        let diskC = "caf\u{00E9}"
        let localText = "Local edits"
        let session = DocumentSession(text: diskA, fileKind: .markdown)
        session.replaceText(localText)
        let editedVersion = session.version
        let editedStatistics = session.statistics

        session.rebaseSavedText(to: diskC)

        XCTAssertTrue(ExactSourceText.matches(session.text, localText))
        XCTAssertEqual(session.version, editedVersion)
        XCTAssertEqual(session.statistics, editedStatistics)
        XCTAssertTrue(session.isDirty)

        session.replaceText(diskC)
        XCTAssertFalse(session.isDirty)

        session.replaceText(diskA)
        XCTAssertTrue(session.isDirty)
    }

    func testRebaseSavedTextClearsDirtyWhenCurrentTextExactlyMatchesNewBaseline() {
        let session = DocumentSession(text: "Disk A", fileKind: .markdown)
        session.replaceText("Disk C")
        let editedVersion = session.version

        session.rebaseSavedText(to: "Disk C")

        XCTAssertEqual(session.text, "Disk C")
        XCTAssertEqual(session.version, editedVersion)
        XCTAssertFalse(session.isDirty)
    }

    func testApplyStatisticsReplacesStatistics() {
        let session = DocumentSession(text: "One two")

        session.applyStatistics(TextStatistics(text: "One two three"))

        XCTAssertEqual(session.statistics.wordCount, 3)
        XCTAssertEqual(session.statistics, TextStatistics(text: "One two three"))
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

    func testResetPropagatesCanonicalEquivalentRawDifferentText() async throws {
        let original = "cafe\u{0301}"
        let replacement = "caf\u{00E9}"
        let fileURL = URL(fileURLWithPath: "/tmp/post.md")
        let session = DocumentSession(text: original, url: fileURL, fileKind: .markdown)
        var iterator = session.textChanges(includeCurrent: false).makeAsyncIterator()

        session.reset(
            text: replacement,
            url: fileURL,
            fileKind: .markdown,
            isDirty: false
        )

        let nextChange = await iterator.next()
        let change = try XCTUnwrap(nextChange)
        XCTAssertEqual(Array(session.text.utf16), Array(replacement.utf16))
        XCTAssertEqual(Array(change.text.utf16), Array(replacement.utf16))
        XCTAssertEqual(session.version, 1)
        XCTAssertFalse(session.isDirty)
    }

    func testTextChangesStreamYieldsInitialReplaceAndMarkSavedChanges() async {
        let session = DocumentSession(
            text: "Original",
            url: URL(fileURLWithPath: "/tmp/original.md"),
            fileKind: .markdown
        )
        var iterator = session.textChanges().makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(
            initial,
            DocumentTextChange(
                text: "Original",
                version: 0,
                fileKind: .markdown,
                fileURL: URL(fileURLWithPath: "/tmp/original.md")
            )
        )

        session.replaceText("Edited", refreshStatistics: false)

        let edit = await iterator.next()
        XCTAssertEqual(
            edit,
            DocumentTextChange(
                text: "Edited",
                version: 1,
                fileKind: .markdown,
                fileURL: URL(fileURLWithPath: "/tmp/original.md")
            )
        )

        session.markSaved(text: "Edited", url: URL(fileURLWithPath: "/tmp/edited.mdx"))

        let saved = await iterator.next()
        XCTAssertEqual(
            saved,
            DocumentTextChange(
                text: "Edited",
                version: 2,
                fileKind: .mdx,
                fileURL: URL(fileURLWithPath: "/tmp/edited.mdx")
            )
        )
    }

    func testTextChangesStreamYieldsResetChanges() async {
        let session = DocumentSession(
            text: "Original",
            url: URL(fileURLWithPath: "/tmp/original.md"),
            fileKind: .markdown
        )
        var iterator = session.textChanges(includeCurrent: false).makeAsyncIterator()

        session.reset(
            text: "Reset",
            url: URL(fileURLWithPath: "/tmp/reset.md"),
            fileKind: .markdown,
            isDirty: false
        )

        let reset = await iterator.next()
        XCTAssertEqual(
            reset,
            DocumentTextChange(
                text: "Reset",
                version: 1,
                fileKind: .markdown,
                fileURL: URL(fileURLWithPath: "/tmp/reset.md")
            )
        )
    }
}
