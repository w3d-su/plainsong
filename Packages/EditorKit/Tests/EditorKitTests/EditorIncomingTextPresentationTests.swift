import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

/// `updateRepresentedTextView` installs incoming App text through
/// `MarkdownTextViewCoordinator.assignWholeSource`, which restores the clamped selection
/// and discards the presentation bookkeeping the write erased. The image reset is the
/// point: `WYSIWYGImagePresentationController` recognises a changed source by a UTF-16
/// length-plus-endpoints sample, so a same-length candidate with identical ends would
/// otherwise keep believing markers that `textView.text =` wiped.
@MainActor
final class EditorIncomingTextPresentationTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    /// One incoming App text change: same UTF-16 length, same first and last 64 units, one
    /// character changed more than 128 units from both ends, same image. The assignment
    /// leaves the storage raw but must already have re-materialised the live Find request —
    /// the cache may never claim a decoration the storage no longer carries. The ordinary
    /// parse the App text change schedules then restores marker and folds equal to an
    /// independent fresh parse, with no further input.
    func testIncomingSameLengthSameEndsSourceRestoresPresentationAfterTheOrdinaryParse() async throws {
        let original = Self.longSource(word: "wprd")
        let incoming = Self.longSource(word: "word")
        let changed = (original as NSString).range(of: "wprd").location + 1
        XCTAssertGreaterThan(changed, 128)
        XCTAssertGreaterThan(original.utf16.count - changed, 128)
        XCTAssertEqual(original.utf16.count, incoming.utf16.count)
        XCTAssertNotEqual(original, incoming)
        let imageRange = (original as NSString).range(of: "![alt](fixture.png)")
        let match = (original as NSString).range(of: "bold")
        let find = EditorFindMatchHighlightRequest(generation: 1, matches: [match], currentIndex: 0)
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: original,
            selection: NSRange(location: 3, length: 0),
            enableWYSIWYG: true,
            findMatchHighlight: find,
            imageThumbnailConfiguration: Self.imageConfiguration
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        driver.installInitialPresentation()
        _ = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
            in: fixture.textView, range: imageRange, matching: { $0.visualState == .failed }
        )
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        XCTAssertNotNil(findMarker(in: storage, at: match.location))

        fixture.model.source = incoming
        fixture.model.revision = 1
        fixture.representable.updateRepresentedTextView(
            fixture.scrollView, coordinator: fixture.coordinator
        )

        XCTAssertTrue(ExactUTF16Text.matches(
            EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), incoming
        ))
        try EditorReconciledPresentationTestDriver.assertRawPending(
            in: fixture, source: incoming, selection: NSRange(location: 3, length: 0)
        )
        XCTAssertEqual(
            driver.requestCount, 0,
            "the incoming path relies on the App text change's parse, not the #144 request"
        )
        XCTAssertNotNil(
            findMarker(in: storage, at: match.location),
            "the same update must re-materialise the still-live Find request"
        )
        XCTAssertEqual(fixture.coordinator.appliedFindMatchHighlight, find)

        // The ordinary parse for the new App text, applied without any other input.
        driver.installInitialPresentation()
        try await EditorReconciledPresentationTestDriver.assertMatchesFreshParse(
            in: fixture, presentation: driver.presentation, findDecoration: find
        )
    }

    /// An identical App candidate must not assign at all: a whole-source write would still
    /// wipe every storage attribute. The storage edit counter proves no character edit ran.
    func testIdenticalIncomingSourceDoesNotAssign() throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: Self.longSource(word: "word"),
            selection: NSRange(location: 3, length: 0),
            enableWYSIWYG: true
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        driver.installInitialPresentation()
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        var characterEdits = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { notification in
            if (notification.object as? NSTextStorage)?.editedMask.contains(.editedCharacters) == true {
                characterEdits += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        fixture.representable.updateRepresentedTextView(
            fixture.scrollView, coordinator: fixture.coordinator
        )

        XCTAssertEqual(characterEdits, 0, "an identical candidate must not rewrite storage")
        XCTAssertNotNil(fixture.textView.replacePresentationSnapshot)
        XCTAssertNotNil(fixture.coordinator.lastAppliedHighlightFoldPlan)
    }

    /// U+212B ANGSTROM SIGN and U+00C5 are one UTF-16 unit each and Swift treats them as
    /// equal; the incoming-text check is literal UTF-16, so the candidate must still assign.
    func testSameLengthCanonicallyEquivalentIncomingSourceStillAssigns() throws {
        let original = "Lead \u{212B} tail"
        let incoming = "Lead \u{00C5} tail"
        XCTAssertEqual(original, incoming)
        XCTAssertEqual(original.utf16.count, incoming.utf16.count)
        XCTAssertFalse(ExactUTF16Text.matches(original, incoming))
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: original)
        fixture.model.source = incoming
        fixture.model.revision = 1

        fixture.representable.updateRepresentedTextView(
            fixture.scrollView, coordinator: fixture.coordinator
        )

        let native = EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView)
        XCTAssertTrue(ExactUTF16Text.matches(native, incoming))
        XCTAssertEqual((native as NSString).character(at: 5), 0x00C5)
    }

    /// The same source at a newer App revision still takes the exact-match early return:
    /// nothing is assigned, the installed presentation is untouched, and the new snapshot
    /// is accepted.
    func testIdenticalSourceAtANewerRevisionDoesNotAssign() throws {
        let source = Self.longSource(word: "word")
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source,
            enableWYSIWYG: true
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        driver.installInitialPresentation()
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        var characterEdits = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { notification in
            if (notification.object as? NSTextStorage)?.editedMask.contains(.editedCharacters) == true {
                characterEdits += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        fixture.model.revision = 1
        fixture.representable.updateRepresentedTextView(
            fixture.scrollView, coordinator: fixture.coordinator
        )

        XCTAssertEqual(characterEdits, 0, "an unchanged candidate must not rewrite storage")
        XCTAssertEqual(fixture.coordinator.currentInstalledSourceSnapshot?.revision, 1)
        XCTAssertNotNil(fixture.textView.replacePresentationSnapshot)
        XCTAssertNotNil(fixture.coordinator.lastAppliedHighlightFoldPlan)
    }

    /// The marked-text guard is unchanged: the candidate defers, the commit publishes, and
    /// the deferred document-transition retry installs the refreshed source through
    /// `assignWholeSource` — proven by the presentation bookkeeping it discards and the
    /// live Find request the same installation pass re-materialises.
    func testIncomingSourceWhileMarkedTextExistsDefersToTheRetry() async throws {
        let original = Self.longSource(word: "wprd")
        let match = (original as NSString).range(of: "bold")
        let find = EditorFindMatchHighlightRequest(generation: 1, matches: [match], currentIndex: 0)
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: original,
            selection: NSRange(location: (original as NSString).length, length: 0),
            enableWYSIWYG: true,
            findMatchHighlight: find
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        driver.installInitialPresentation()
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        XCTAssertNotNil(fixture.coordinator.lastAppliedHighlightFoldPlan)
        XCTAssertNotNil(fixture.textView.replacePresentationSnapshot)
        XCTAssertNotNil(findMarker(in: storage, at: match.location))

        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )

        fixture.model.source = "Superseded while marked"
        fixture.model.revision = 1
        fixture.representable.updateRepresentedTextView(
            fixture.scrollView, coordinator: fixture.coordinator
        )
        XCTAssertEqual(
            EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), original + "ㄊ"
        )

        fixture.textView.insertText("台", replacementRange: .notFound)
        let committed = original + "台"
        for _ in 0 ..< 16 {
            await Task.yield()
        }

        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), committed)
        XCTAssertEqual(fixture.model.source, committed)
        XCTAssertTrue(fixture.coordinator.isPreparedDocumentInstalled)
        XCTAssertNil(
            fixture.coordinator.lastAppliedHighlightFoldPlan,
            "the retry's whole-source assignment must discard the stale fold plan"
        )
        XCTAssertNil(
            fixture.textView.replacePresentationSnapshot,
            "the retry's whole-source assignment must discard the stale presentation snapshot"
        )
        XCTAssertNotNil(
            findMarker(in: storage, at: match.location),
            "the deferred installation must re-materialise the live Find request"
        )
    }

    /// Direct pin for the shared helper every assignment site routes through: assigning a
    /// same-length, same-ends source must clear stale image ownership so the next parse
    /// rebuilds the marker. The deferred retry cannot be distinguished from the incoming
    /// path at the controller level — both share this helper, pinned by the source guard.
    func testAssignWholeSourceClearsStaleImageOwnershipForTheNextParse() async throws {
        let original = Self.longSource(word: "wprd")
        let incoming = Self.longSource(word: "word")
        let imageRange = (original as NSString).range(of: "![alt](fixture.png)")
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: original,
            selection: NSRange(location: 3, length: 0),
            enableWYSIWYG: true
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        EditorReconciledPresentationTestDriver.configureImages(in: fixture)
        driver.installInitialPresentation()
        _ = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
            in: fixture.textView, range: imageRange, matching: { $0.visualState == .failed }
        )

        fixture.coordinator.assignWholeSource(incoming, to: fixture.textView)
        fixture.model.source = incoming
        fixture.model.revision = 1

        try EditorReconciledPresentationTestDriver.assertRawPending(
            in: fixture, source: incoming, selection: NSRange(location: 3, length: 0)
        )
        driver.installInitialPresentation()
        try await EditorReconciledPresentationTestDriver.assertMatchesFreshParse(
            in: fixture, presentation: driver.presentation
        )
    }

    /// The image configuration arrives on the representable, as it does from App:
    /// `completeDocumentInstallation` pushes it to the controller on every install.
    private static var imageConfiguration: EditorImageThumbnailConfiguration {
        EditorImageThumbnailConfiguration(
            loader: TestEditorImageThumbnailLoader(outcomes: [:]),
            rootURL: URL(fileURLWithPath: "/tmp/PlainsongIncomingTextTests"),
            documentDirectoryRelativePath: ""
        )
    }

    /// A document whose mid-document word sits more than 128 UTF-16 units from both ends.
    private static func longSource(word: String) -> String {
        String(repeating: "Lead paragraph with **bold** words. ", count: 6)
            + "\nMiddle \(word) here.\n![alt](fixture.png)\n"
            + String(repeating: "Tail paragraph with *italic* words. ", count: 6)
    }

    private func findMarker(in storage: NSTextStorage, at location: Int) -> EditorFindMatchHighlightMarker? {
        storage.attribute(
            EditorFindMatchHighlightMarker.attribute, at: location, effectiveRange: nil
        ) as? EditorFindMatchHighlightMarker
    }
}
