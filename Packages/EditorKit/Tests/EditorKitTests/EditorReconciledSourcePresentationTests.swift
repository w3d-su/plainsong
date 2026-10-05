import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import SwiftUI
import XCTest

@MainActor
final class EditorReconciledSourcePresentationTests: XCTestCase {
    private let source = "# Heading\nIntro **bold** [link](https://host/a) ![alt](fixture.png)\nTail"

    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testWriterActivationSynchronizationAutomaticallyRederivesPresentationAndClampsSelection() async throws {
        try await assertWriterActivationRestore(rejected: false)
    }

    func testRejectedWriterActivationAutomaticallyRederivesPresentationAndClampsSelection() async throws {
        try await assertWriterActivationRestore(rejected: true)
    }

    func testAcceptedReconciledPublicationAutomaticallyRederivesPresentationAndClampsSelection() async throws {
        try await assertPublicationRestore(rejected: false)
    }

    func testRejectedPublicationAutomaticallyRederivesPresentationAndClampsSelection() async throws {
        try await assertPublicationRestore(rejected: true)
    }

    func testSourceModeReconciliationAutomaticallyRestoresHighlightingWithoutInput() async throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source + "\nStale suffix",
            selection: NSRange(location: 0, length: 0)
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture, presentation: .source)
        defer { driver.stop() }
        driver.installInitialPresentation()
        fixture.model.source = source
        fixture.model.revision = 1

        XCTAssertFalse(fixture.coordinator.preflightTextMutation(in: fixture.textView))

        XCTAssertEqual(driver.requestCount, 1)
        try EditorReconciledPresentationTestDriver.assertRawPending(
            in: fixture, source: source, selection: NSRange(location: 0, length: 0)
        )
        try await driver.releaseAndWaitForApply()
        try await EditorReconciledPresentationTestDriver.assertMatchesFreshParse(
            in: fixture, presentation: .source, includesImage: false
        )
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        let heading = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(heading.pointSize, MarkdownSyntaxHighlighter.defaultFont.pointSize)
        XCTAssertEqual(fixture.model.publications, [])
    }

    /// Reconciliation completes before this composition begins; only the pending
    /// presentation apply is blocked here. During marked text, publication defers
    /// upstream, writer activation is skipped, and App's pending-source fence applies.
    func testPendingReconciliationPresentationSkipsMarkedTextWithoutCorruptingComposition() async throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source + "\nStale suffix",
            selection: NSRange(location: 0, length: 0),
            enableWYSIWYG: true
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        driver.installInitialPresentation()
        fixture.model.source = source
        fixture.model.revision = 1
        XCTAssertFalse(fixture.coordinator.preflightTextMutation(in: fixture.textView))
        try EditorReconciledPresentationTestDriver.assertRawPending(
            in: fixture, source: source, selection: NSRange(location: 0, length: 0)
        )
        fixture.textView.setMarkedText(
            "ㄓ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let composedSource = EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView)
        let composedSelection = fixture.textView.selectedRange()

        try await driver.releaseAndWaitForCompletion()

        XCTAssertTrue(fixture.textView.hasMarkedText())
        XCTAssertEqual(driver.appliedCount, 0, "The existing marked-text apply guard must defer presentation")
        XCTAssertEqual(driver.requestCount, 1)
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), composedSource)
        XCTAssertEqual(fixture.textView.selectedRange(), composedSelection)
        XCTAssertEqual(fixture.model.source, source, "Intermediate composition is never published")
        XCTAssertEqual(fixture.model.publications, [])
        XCTAssertNil(fixture.textView.replacePresentationSnapshot)
    }

    func testMarkedTextPublicationDefersReconciliationUntilCompositionEnds() async throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: source)
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture, presentation: .source)
        defer { driver.stop() }
        driver.installInitialPresentation()
        fixture.textView.setMarkedText(
            "ㄓ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let composed = EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView)
        fixture.model.rejectsPublications = true
        fixture.coordinator.textViewDidChangeText(Notification(
            name: STTextView.textDidChangeNotification,
            object: fixture.textView
        ))
        XCTAssertTrue(fixture.textView.hasMarkedText())
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), composed)
        XCTAssertEqual(driver.requestCount, 0)
        XCTAssertEqual(fixture.model.publications, [])

        fixture.textView.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(driver.requestCount, 1)
        XCTAssertFalse(fixture.textView.hasMarkedText())
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), source)
        let couldUndo = fixture.textView.undoManager?.canUndo
        let couldRedo = fixture.textView.undoManager?.canRedo
        try await driver.releaseAndWaitForApply()
        try await EditorReconciledPresentationTestDriver.assertMatchesFreshParse(
            in: fixture, presentation: .source, includesImage: false, assertsNoUndoStep: false
        )
        XCTAssertEqual(fixture.textView.undoManager?.canUndo, couldUndo)
        XCTAssertEqual(fixture.textView.undoManager?.canRedo, couldRedo)
    }

    func testReconciliationRejectsOlderPresentationRevisionBeforeAndAfterFreshApply() async throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source,
            selection: NSRange(location: 0, length: 0),
            enableWYSIWYG: true
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        let applied = driver.installInitialPresentation()
        let older = driver.prepareUnappliedPresentation(selection: NSRange(location: 0, length: 0))
        fixture.coordinator.isUpdating = true
        fixture.textView.textSelection = (source as NSString).range(of: "bold")
        fixture.coordinator.isUpdating = false
        // The source remains identical, so source equality alone cannot reject an
        // already-returning parse from an obsolete selection or document context.
        fixture.coordinator.applyReconciledSource(source, replacing: source, in: fixture.textView)
        XCTAssertEqual(fixture.coordinator.minimumHighlightRevisionAfterReconciliation, driver.revision)
        XCTAssertEqual(fixture.coordinator.lastAppliedHighlightRevision, applied.revision)
        XCTAssertGreaterThan(older.revision, applied.revision,
                             "The stale result was produced but never installed")
        XCTAssertFalse(fixture.coordinator.canApplyHighlightRevision(older.revision))
        XCTAssertTrue(fixture.coordinator.canApplyHighlightRevision(driver.revision))
        try EditorReconciledPresentationTestDriver.assertRawPending(
            in: fixture, source: source, selection: (source as NSString).range(of: "bold")
        )

        try await driver.releaseAndWaitForApply()

        XCTAssertFalse(fixture.coordinator.canApplyHighlightRevision(older.revision),
                       "A completed newer pass must never reopen admission for an older parse")
        XCTAssertTrue(fixture.coordinator.canApplyHighlightRevision(driver.revision + 1))
        XCTAssertEqual(fixture.textView.replacePresentationSnapshot?.styledText.revision, driver.revision)
    }

    func testOrdinaryNativeEditDoesNotRequestReconciliationPresentation() throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source,
            selection: NSRange(location: (source as NSString).length, length: 0)
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture, presentation: .source)
        defer { driver.stop() }
        driver.installInitialPresentation()

        fixture.textView.insertText("!", replacementRange: fixture.textView.selectedRange())

        XCTAssertEqual(fixture.model.source, source + "!")
        XCTAssertEqual(fixture.model.publications, [source + "!"])
        XCTAssertEqual(driver.requestCount, 0, "Ordinary typing adds no reconciliation scheduler work")
        XCTAssertNil(fixture.coordinator.minimumHighlightRevisionAfterReconciliation)
        XCTAssertTrue(fixture.textView.undoManager?.canUndo == true)
    }

    func testWriterActivationClampPublishesCaretBeforeWYSIWYGReparseAcrossHeadingBoundary() async throws {
        for rejected in [false, true] {
            let restored = "Intro\n## Heading"
            let stale = restored + " stale suffix"
            let staleSelection = NSRange(location: (stale as NSString).length - 1, length: 0)
            var boundSelection: NSRange? = staleSelection
            let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
                source: stale, selection: staleSelection, enableWYSIWYG: true,
                selectionBinding: Binding(get: { boundSelection }, set: { boundSelection = $0 })
            )
            let driver = EditorReconciledPresentationTestDriver(
                fixture: fixture, selectionProvider: { boundSelection }
            )
            defer { driver.stop() }
            let initial = driver.installInitialPresentation()
            XCTAssertTrue(try XCTUnwrap(initial.foldPlan?.regions.first { $0.kind == .heading(level: 2) }).isRevealed)
            fixture.model.source = restored
            fixture.model.revision = 1
            fixture.model.rejectsWriterActivations = rejected

            XCTAssertFalse(fixture.coordinator.preflightTextMutation(in: fixture.textView))

            let clamped = NSRange(location: (restored as NSString).length, length: 0)
            XCTAssertEqual(boundSelection, clamped)
            XCTAssertEqual(driver.selectionAtRequest, clamped, "The scheduler must see the published clamp")
            XCTAssertEqual(driver.requestCount, 1)
            try await driver.releaseAndWaitForApply()
            try await EditorReconciledPresentationTestDriver.assertMatchesFreshParse(
                in: fixture, presentation: driver.presentation, includesImage: false
            )
            let plan = try XCTUnwrap(fixture.coordinator.lastAppliedHighlightFoldPlan)
            XCTAssertFalse(try XCTUnwrap(plan.regions.first { $0.kind == .heading(level: 2) }).isRevealed)
            XCTAssertFalse(plan.foldedRanges.isEmpty)
            XCTAssertEqual(fixture.model.publications, [])
        }
    }

    private func assertWriterActivationRestore(rejected: Bool) async throws {
        let stale = source + "\nStale suffix"
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: stale,
            selection: NSRange(location: (stale as NSString).length - 2, length: 2),
            enableWYSIWYG: true
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        EditorReconciledPresentationTestDriver.configureImages(in: fixture)
        let initial = driver.installInitialPresentation()
        XCTAssertFalse(initial.foldPlan?.foldedRanges.isEmpty == true)
        fixture.model.source = source
        fixture.model.revision = 1
        fixture.model.rejectsWriterActivations = rejected

        XCTAssertFalse(fixture.coordinator.preflightTextMutation(in: fixture.textView))

        let selection = NSRange(location: (source as NSString).length, length: 0)
        XCTAssertEqual(driver.requestCount, 1)
        XCTAssertEqual(fixture.coordinator.currentInstalledSourceSnapshot, fixture.model.snapshot)
        try EditorReconciledPresentationTestDriver.assertRawPending(in: fixture, source: source, selection: selection)
        try await driver.releaseAndWaitForApply()
        try await EditorReconciledPresentationTestDriver.assertMatchesFreshParse(
            in: fixture,
            presentation: driver.presentation
        )
        XCTAssertEqual(driver.requestCount, 1)
        XCTAssertEqual(fixture.textView.selectedRange(), selection)
        XCTAssertEqual(fixture.model.publications, [])
        XCTAssertEqual(fixture.model.revision, 1)
    }

    private func assertPublicationRestore(rejected: Bool) async throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source,
            selection: NSRange(location: (source as NSString).length, length: 0),
            enableWYSIWYG: true
        )
        let driver = EditorReconciledPresentationTestDriver(fixture: fixture)
        defer { driver.stop() }
        EditorReconciledPresentationTestDriver.configureImages(in: fixture)
        driver.installInitialPresentation()
        // Reconcile only after the first image plan has settled, so changing no
        // source length cannot accidentally stand in for presentationWasReset.
        _ = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
            in: fixture.textView,
            range: (source as NSString).range(of: "![alt](fixture.png)"),
            matching: { $0.visualState == .failed }
        )
        let native = source + "\nUnpublished suffix"
        fixture.coordinator.isUpdating = true
        fixture.textView.text = native
        fixture.textView.textSelection = NSRange(location: (native as NSString).length - 2, length: 2)
        fixture.coordinator.isUpdating = false
        fixture.coordinator.isNativeSourceSynchronized = false
        fixture.model.rejectsPublications = rejected
        if !rejected { fixture.model.reconcilesPublication = { _ in self.source } }

        fixture.coordinator.textViewDidChangeText(Notification(
            name: STTextView.textDidChangeNotification,
            object: fixture.textView
        ))

        let selection = NSRange(location: (source as NSString).length, length: 0)
        XCTAssertEqual(driver.requestCount, 1)
        XCTAssertEqual(fixture.model.publications, [native])
        XCTAssertEqual(fixture.coordinator.currentInstalledSourceSnapshot, fixture.model.snapshot)
        try EditorReconciledPresentationTestDriver.assertRawPending(in: fixture, source: source, selection: selection)
        try await driver.releaseAndWaitForApply()
        try await EditorReconciledPresentationTestDriver.assertMatchesFreshParse(
            in: fixture,
            presentation: driver.presentation
        )
        XCTAssertEqual(driver.requestCount, 1)
        XCTAssertEqual(fixture.textView.selectedRange(), selection)
        XCTAssertEqual(fixture.model.source, source)
        XCTAssertEqual(fixture.model.revision, rejected ? 0 : 1)
    }
}
