import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// The actual coordinator delegate must wake a selection-protected trim without
/// republishing an unchanged viewport or extending its settle delay on duplicate events.
@MainActor
final class EditorCacheTrimSelectionReportingTests: XCTestCase {
    private typealias Support = EditorFindControllerTestSupport
    private var fixtures: [Support.WindowedFixture] = []

    override func tearDown() {
        for fixture in fixtures {
            fixture.coordinator.detachVisibleRangeReporter()
            fixture.coordinator.textElementCacheTrimmer.probeHandler = nil
        }
        fixtures.removeAll()
        Support.tearDownWindows()
        super.tearDown()
    }

    func testSelectionOnlyChangeSchedulesOnceWithoutRepublishingTheViewport() throws {
        let fixture = try makeFixture()
        let editor = fixture.textView
        let coordinator = fixture.coordinator
        let viewport = try XCTUnwrap(MarkdownTextView.visibleTextRange(of: editor))
        var schedules = 0
        var publications: [NSRange] = []
        coordinator.textElementCacheTrimmer.probeHandler = { event, _ in
            if event == "schedule" {
                schedules += 1
            }
        }
        coordinator.attachVisibleRangeReporter({ publications.append($0) }, to: editor)
        XCTAssertEqual(schedules, 1)
        XCTAssertEqual(publications, [viewport])

        // Native selection notifications call the coordinator's installed textDelegate.
        editor.textSelection = NSRange(location: 5, length: 0)

        XCTAssertEqual(MarkdownTextView.visibleTextRange(of: editor), viewport)
        XCTAssertEqual(schedules, 2)
        XCTAssertEqual(publications, [viewport], "selection-only changes do not restart highlighting")
        editor.textSelection = NSRange(location: 5, length: 0)
        coordinator.reportVisibleRangeIfNeeded(in: editor)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: editor))
        storage.beginEditing()
        storage.edited(.editedAttributes, range: NSRange(location: 0, length: 1), changeInLength: 0)
        storage.endEditing()
        coordinator.reportVisibleRangeIfNeeded(in: editor)
        XCTAssertEqual(schedules, 2, "duplicate selection and attribute observations keep the existing timer")
        XCTAssertEqual(publications, [viewport])
    }

    func testTrimResumesWhenSelectionProtectionShrinksWithinTheSameViewport() async throws {
        let fixture = try makeFixture()
        let editor = fixture.textView
        let coordinator = fixture.coordinator
        let length = try XCTUnwrap(MarkdownTextView.textStorage(of: editor)?.length)
        editor.textSelection = NSRange(location: 0, length: length)
        let trimmer = coordinator.textElementCacheTrimmer
        let initialTrimmedLength = trimmer.trimmedLength
        var schedules = 0
        var refused = false
        var releases = 0
        var publications: [NSRange] = []
        trimmer.probeHandler = { event, _ in
            if event == "schedule" {
                schedules += 1
            }
            if event == "refused" {
                refused = true
            }
            if event == "trimmed" {
                releases += 1
            }
        }
        coordinator.attachVisibleRangeReporter({ publications.append($0) }, to: editor)
        try await Support.waitUntil(timeout: 5) { refused }
        XCTAssertTrue(refused)
        XCTAssertEqual(releases, 0, "a selection covering the document must remain protected")
        XCTAssertEqual(trimmer.trimmedLength, initialTrimmedLength)
        // Select All schedules native layout, which may finish during the settle
        // await and change TextKit's prefetched viewport. Report that real change
        // before measuring the selection-only transition below.
        coordinator.reportVisibleRangeIfNeeded(in: editor)
        let viewport = try XCTUnwrap(MarkdownTextView.visibleTextRange(of: editor))
        XCTAssertEqual(publications.last, viewport)
        let publicationsBeforeCollapse = publications
        let schedulesBeforeCollapse = schedules

        // No scroll or fresh visible-range report accompanies collapsing Select All.
        editor.textSelection = NSRange(location: 0, length: 0)
        XCTAssertEqual(MarkdownTextView.visibleTextRange(of: editor), viewport)
        XCTAssertEqual(schedules, schedulesBeforeCollapse + 1)
        try await Support.waitUntil(timeout: 5) { trimmer.trimmedLength > initialTrimmedLength }

        XCTAssertGreaterThan(trimmer.trimmedLength, initialTrimmedLength)
        XCTAssertGreaterThan(releases, 0)
        XCTAssertEqual(publications, publicationsBeforeCollapse)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testDetachingClearsTheSelectionScheduleKeyBeforeReattachment() throws {
        let fixture = try makeFixture()
        let coordinator = fixture.coordinator
        var schedules = 0
        coordinator.textElementCacheTrimmer.probeHandler = { event, _ in
            if event == "schedule" {
                schedules += 1
            }
        }
        coordinator.attachVisibleRangeReporter({ _ in }, to: fixture.textView)
        coordinator.detachVisibleRangeReporter()
        coordinator.attachVisibleRangeReporter({ _ in }, to: fixture.textView)
        XCTAssertEqual(schedules, 2)
    }

    private func makeFixture() throws -> Support.WindowedFixture {
        let source = String(repeating: "line of text\n", count: 20000)
        let model = Support.FindNavModel(text: source, selection: NSRange(location: 0, length: 0))
        let fixture = try Support.makeWindowedFixture(
            model: model,
            source: source,
            documentIdentity: EditorDocumentIdentity(rawValue: "cache-trim-selection")
        )
        fixture.textView.textSelection = NSRange(location: 0, length: 0)
        fixture.coordinator.detachVisibleRangeReporter()
        fixtures.append(fixture)
        return fixture
    }
}
