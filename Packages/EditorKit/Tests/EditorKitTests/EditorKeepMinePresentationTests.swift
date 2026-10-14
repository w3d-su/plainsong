import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

/// Keep Mine hands the editor the *unchanged* session snapshot through the exact-installation
/// synchronizer App retains. Whole-source assignment would erase every presentation attribute
/// even though `text` did not change, and nothing would schedule a reparse. These tests drive
/// that synchronizer directly: with no further input, the settled presentation must still equal
/// an independent fresh parse.
@MainActor
final class EditorKeepMinePresentationTests: XCTestCase {
    private let source = "# Heading\nIntro **bold** [link](https://host/a) ![alt](fixture.png)\nTail"

    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testUnchangedSnapshotKeepsWYSIWYGPresentationFindDecorationAndMarkersWithoutInput() async throws {
        let tail = (source as NSString).range(of: "Tail")
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source, selection: tail, enableWYSIWYG: true
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        EditorReconciledPresentationTestDriver.configureImages(in: fixture)
        let initial = driver.installInitialPresentation()
        _ = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
            in: fixture.textView,
            range: (source as NSString).range(of: "![alt](fixture.png)"),
            matching: { $0.visualState == .failed }
        )
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        let match = (source as NSString).range(of: "bold")
        let find = EditorFindMatchHighlightRequest(generation: 1, matches: [match], currentIndex: 0)
        applyFindDecoration(find, in: fixture)
        XCTAssertFalse(initial.foldPlan?.foldedRanges.isEmpty == true)
        let markerBefore = try XCTUnwrap(findMarker(in: storage, at: match.location))
        let appliedRevision = fixture.coordinator.lastAppliedHighlightRevision
        let foldPlanBefore = fixture.coordinator.lastAppliedHighlightFoldPlan
        let snapshotBefore = fixture.textView.replacePresentationSnapshot

        XCTAssertTrue(try XCTUnwrap(fixture.model.sourceSynchronizer)(fixture.model.snapshot))

        // No release of any scheduler wait, edit, selection change or representable update.
        XCTAssertEqual(driver.requestCount, 0)
        XCTAssertNil(fixture.coordinator.minimumHighlightRevisionAfterReconciliation)
        XCTAssertEqual(fixture.coordinator.lastAppliedHighlightRevision, appliedRevision)
        XCTAssertEqual(fixture.coordinator.lastAppliedHighlightFoldPlan, foldPlanBefore)
        XCTAssertNotNil(fixture.coordinator.lastAppliedHighlightFoldPlan)
        XCTAssertEqual(fixture.textView.replacePresentationSnapshot?.styledText.revision,
                       snapshotBefore?.styledText.revision)
        XCTAssertTrue(markerBefore === findMarker(in: storage, at: match.location),
                      "Find decoration must be the same attribute run, not re-materialised")
        XCTAssertNotNil(fixture.coordinator.appliedFindMatchHighlight)
        XCTAssertEqual(fixture.coordinator.appliedFindMatchHighlightSpan, match)
        try await EditorReconciledPresentationTestDriver.assertMatchesFreshParse(
            in: fixture, presentation: driver.presentation, findDecoration: find
        )
        XCTAssertEqual(fixture.textView.selectedRange(), tail)
        XCTAssertEqual(fixture.coordinator.currentInstalledSourceSnapshot, fixture.model.snapshot)
        XCTAssertEqual(fixture.model.publications, [])
        XCTAssertEqual(fixture.model.revision, 0)
    }

    func testSameSourceAtANewRevisionKeepsPresentationAndAcceptsTheSnapshot() async throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source, selection: NSRange(location: 4, length: 3), enableWYSIWYG: true
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        driver.installInitialPresentation()
        fixture.model.revision = 3

        XCTAssertTrue(try XCTUnwrap(fixture.model.sourceSynchronizer)(fixture.model.snapshot))

        XCTAssertEqual(driver.requestCount, 0)
        XCTAssertEqual(fixture.coordinator.currentInstalledSourceSnapshot?.revision, 3)
        XCTAssertTrue(fixture.coordinator.isNativeSourceSynchronized)
        try await EditorReconciledPresentationTestDriver.assertMatchesFreshParse(
            in: fixture, presentation: driver.presentation, includesImage: false
        )
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 4, length: 3))
    }

    func testUnchangedSnapshotKeepsSourceModeHighlightingWithoutInput() async throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source, selection: NSRange(location: 0, length: 0)
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture, presentation: .source)
        defer { driver.stop() }
        driver.installInitialPresentation()
        let heading = try XCTUnwrap(
            MarkdownTextView.textStorage(of: fixture.textView)?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        )
        XCTAssertGreaterThan(heading.pointSize, MarkdownSyntaxHighlighter.defaultFont.pointSize)

        XCTAssertTrue(try XCTUnwrap(fixture.model.sourceSynchronizer)(fixture.model.snapshot))

        XCTAssertEqual(driver.requestCount, 0)
        try await EditorReconciledPresentationTestDriver.assertMatchesFreshParse(
            in: fixture, presentation: .source, includesImage: false
        )
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    /// Reload with different text still goes through the whole-source assignment: the
    /// App text binding changes with it, so the normal text-change path re-derives.
    func testChangedSnapshotStillReplacesNativeSourceClampsSelectionAndAddsNoUndo() throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source,
            selection: NSRange(location: (source as NSString).length - 2, length: 2),
            enableWYSIWYG: true
        )
        let reloaded = "# Disk\nShort"
        fixture.model.source = reloaded
        fixture.model.revision = 1

        XCTAssertTrue(try XCTUnwrap(fixture.model.sourceSynchronizer)(fixture.model.snapshot))

        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), reloaded)
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: (reloaded as NSString).length, length: 0))
        XCTAssertEqual(fixture.coordinator.currentInstalledSourceSnapshot, fixture.model.snapshot)
        XCTAssertFalse(fixture.textView.undoManager?.canUndo == true)
        XCTAssertFalse(fixture.textView.undoManager?.canRedo == true)
        XCTAssertEqual(fixture.model.publications, [])
    }

    /// The skip is an exact UTF-16 comparison, not Swift canonical equivalence: a snapshot
    /// that differs only in normalization form is a different source and must be installed.
    func testCanonicallyEquivalentButDistinctSnapshotStillReplacesNativeSource() throws {
        let precomposed = "caf\u{00E9} **bold**"
        let decomposed = "cafe\u{0301} **bold**"
        XCTAssertEqual(precomposed, decomposed)
        XCTAssertNotEqual(precomposed.utf16.count, decomposed.utf16.count)
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: precomposed)
        fixture.model.source = decomposed
        fixture.model.revision = 1

        XCTAssertTrue(try XCTUnwrap(fixture.model.sourceSynchronizer)(fixture.model.snapshot))

        XCTAssertTrue(ExactUTF16Text.matches(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), decomposed))
        XCTAssertEqual(fixture.coordinator.currentInstalledSourceSnapshot, fixture.model.snapshot)
    }

    /// Reload text with the same length, the same first and last 64 UTF-16 units and the same
    /// image, differing by one character in the middle. The image controller's recorded-source
    /// check is a length-plus-endpoints sample, so only an explicit reset after the whole-source
    /// assignment makes it rebuild a marker that the assignment erased; the ordinary parse that
    /// the App text change schedules is then enough, with no further input.
    func testSameLengthMidDocumentReloadRestoresImageMarkerAfterTheNormalParse() async throws {
        let original = Self.longSource(word: "wprd")
        let reloaded = Self.longSource(word: "word")
        let changed = (original as NSString).range(of: "wprd").location + 1
        XCTAssertGreaterThan(changed, 128)
        XCTAssertGreaterThan(original.utf16.count - changed, 128)
        XCTAssertEqual(original.utf16.count, reloaded.utf16.count)
        XCTAssertNotEqual(original, reloaded)
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: original, selection: NSRange(location: 3, length: 0), enableWYSIWYG: true
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        EditorReconciledPresentationTestDriver.configureImages(in: fixture)
        driver.installInitialPresentation()
        let imageRange = (original as NSString).range(of: "![alt](fixture.png)")
        _ = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
            in: fixture.textView, range: imageRange, matching: { $0.visualState == .failed }
        )
        fixture.model.source = reloaded
        fixture.model.revision = 1

        XCTAssertTrue(try XCTUnwrap(fixture.model.sourceSynchronizer)(fixture.model.snapshot))

        XCTAssertTrue(ExactUTF16Text.matches(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), reloaded))
        try EditorReconciledPresentationTestDriver.assertRawPending(
            in: fixture, source: reloaded, selection: NSRange(location: 3, length: 0)
        )
        XCTAssertEqual(driver.requestCount, 0, "Reload relies on the App text change, not the #144 request")
        // The ordinary parse for the new App text, applied without any other input.
        driver.installInitialPresentation()
        try await EditorReconciledPresentationTestDriver.assertMatchesFreshParse(
            in: fixture, presentation: driver.presentation
        )
    }

    /// U+212B ANGSTROM SIGN and U+00C5 are one UTF-16 unit each and Swift treats them as equal;
    /// the comparison is literal UTF-16, so the snapshot must still be installed.
    func testSingleUnitCanonicallyEquivalentSnapshotStillReplacesNativeSource() throws {
        let angstrom = "\u{212B} **bold**"
        let aring = "\u{00C5} **bold**"
        XCTAssertEqual(angstrom, aring)
        XCTAssertEqual(angstrom.utf16.count, aring.utf16.count)
        XCTAssertFalse(ExactUTF16Text.matches(angstrom, aring))
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: angstrom)
        fixture.model.source = aring
        fixture.model.revision = 1

        XCTAssertTrue(try XCTUnwrap(fixture.model.sourceSynchronizer)(fixture.model.snapshot))

        let native = EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView)
        XCTAssertTrue(ExactUTF16Text.matches(native, aring))
        XCTAssertEqual(native.utf16.first, 0x00C5)
        XCTAssertEqual(fixture.coordinator.currentInstalledSourceSnapshot, fixture.model.snapshot)
    }

    /// Marked text defers synchronization exactly as before, including for an unchanged snapshot.
    func testUnchangedSnapshotWhileMarkedTextExistsStillDefers() throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: source)
        fixture.textView.setMarkedText(
            "ㄓ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let composed = EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView)
        let composedSelection = fixture.textView.selectedRange()
        let snapshotBefore = fixture.coordinator.currentInstalledSourceSnapshot

        XCTAssertFalse(try XCTUnwrap(fixture.model.sourceSynchronizer)(fixture.model.snapshot))

        XCTAssertTrue(fixture.textView.hasMarkedText())
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), composed)
        XCTAssertEqual(fixture.textView.selectedRange(), composedSelection)
        XCTAssertEqual(fixture.coordinator.currentInstalledSourceSnapshot, snapshotBefore)
    }

    /// A document whose mid-document word sits more than 128 UTF-16 units from both ends.
    private static func longSource(word: String) -> String {
        String(repeating: "Lead paragraph with **bold** words. ", count: 6)
            + "\nMiddle \(word) here.\n![alt](fixture.png)\n"
            + String(repeating: "Tail paragraph with *italic* words. ", count: 6)
    }

    private func applyFindDecoration(
        _ request: EditorFindMatchHighlightRequest,
        in fixture: EditorReplaceBatchSpikeSupport.Fixture
    ) {
        guard let storage = MarkdownTextView.textStorage(of: fixture.textView) else { return }
        let coordinator = fixture.coordinator
        coordinator.trackFindHighlightEdits(in: storage)
        coordinator.appliedFindMatchHighlightSpan = EditorFindMatchHighlight.apply(
            request, visibleRange: nil, previouslyDecorated: nil, to: storage
        )
        coordinator.appliedFindMatchHighlightMaterialisation = EditorFindMatchHighlight.materialisationRange(
            for: nil, storageLength: storage.length
        )
        coordinator.appliedFindMatchHighlight = request
    }

    private func findMarker(in storage: NSTextStorage, at location: Int) -> EditorFindMatchHighlightMarker? {
        storage.attribute(
            EditorFindMatchHighlightMarker.attribute, at: location, effectiveRange: nil
        ) as? EditorFindMatchHighlightMarker
    }
}
