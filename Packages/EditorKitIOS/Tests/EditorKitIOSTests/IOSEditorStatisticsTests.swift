import Combine
@testable import EditorKitIOS
@testable import MarkdownCore
import XCTest

/// The document session owns the count (`DocumentSession.scheduleStatisticsRefreshAfterEdit`).
/// These tests await its real 300 ms pause and assert outcomes, not scheduling order.
@MainActor
final class IOSEditorStatisticsTests: XCTestCase {
    func testBurstCountsOnlyTheFinalEditAndPublishesIt() async throws {
        let harness = IOSEditorHarness(text: "")
        var applied = [TextStatistics?]()
        let counts = harness.session.$availableStatistics.dropFirst().sink { applied.append($0) }
        defer { counts.cancel() }
        let snapshots = recordSnapshots(of: harness.controller)
        var tasks = [Task<Void, Never>]()
        for version in 1 ... 5 {
            harness.textView.insertText("甲")
            XCTAssertEqual(harness.session.version, version)
            XCTAssertEqual(harness.session.text, String(repeating: "甲", count: version))
            try tasks.append(XCTUnwrap(harness.session.statisticsTask))
        }
        XCTAssertEqual(tasks.map(\.isCancelled), [true, true, true, true, false])
        await tasks[4].value
        let expected = TextStatistics(text: "甲甲甲甲甲")
        XCTAssertEqual(applied, [expected])
        XCTAssertEqual(snapshots.values.last?.revision.version, 5)
        XCTAssertEqual(snapshots.values.last?.document.availableStatistics, expected)
    }

    func testDetachLeavesTheCountWithItsDocument() async throws {
        let harness = IOSEditorHarness(text: "")
        harness.textView.insertText("甲")
        let task = try XCTUnwrap(harness.session.statisticsTask)
        harness.controller.detach(expected: harness.identity, bindingID: harness.bindingID)
        XCTAssertFalse(task.isCancelled)
        await task.value
        XCTAssertEqual(harness.session.availableStatistics, TextStatistics(text: "甲"))

        harness.controller.attach(binding(for: harness.session, identity: harness.identity))
        XCTAssertNil(harness.session.statisticsTask)
        XCTAssertEqual(harness.controller.captureSnapshot()?.document.availableStatistics, TextStatistics(text: "甲"))
    }

    func testReattachKeepsThePendingCountInsteadOfRestartingIt() async throws {
        let harness = IOSEditorHarness(text: "")
        harness.textView.insertText("甲")
        let task = try XCTUnwrap(harness.session.statisticsTask)
        harness.controller.detach(expected: harness.identity, bindingID: harness.bindingID)
        let snapshots = recordSnapshots(of: harness.controller)
        let rebinding = binding(for: harness.session, identity: harness.identity)
        harness.controller.attach(rebinding)
        XCTAssertEqual(harness.session.statisticsTask, task)
        await task.value
        XCTAssertEqual(snapshots.values.last?.bindingID, rebinding.bindingID)
        XCTAssertEqual(snapshots.values.last?.document.availableStatistics, TextStatistics(text: "甲"))
    }

    func testLateCountStaysWithItsDocumentWhenAnotherHasTheSameSourceAndVersion() async throws {
        let harness = IOSEditorHarness(text: "")
        harness.textView.insertText("甲")
        let task = try XCTUnwrap(harness.session.statisticsTask)
        let second = DocumentSession(text: "another document")
        let secondCounts = second.availableStatistics
        second.replaceText("甲", refreshStatistics: false)
        XCTAssertEqual(second.version, harness.session.version)
        harness.controller.attach(binding(for: second, identity: IOSDocumentIdentity(rawValue: UUID())))
        let snapshots = recordSnapshots(of: harness.controller)
        await task.value
        XCTAssertEqual(harness.session.availableStatistics, TextStatistics(text: "甲"))
        XCTAssertEqual(second.availableStatistics, secondCounts)
        XCTAssertTrue(snapshots.values.isEmpty)
        XCTAssertEqual(harness.controller.captureSnapshot()?.document.availableStatistics, secondCounts)
    }

    func testHostTeardownLetsTheDocumentFinishItsCount() async throws {
        let harness = IOSEditorHarness(text: "")
        harness.textView.insertText("甲")
        let task = try XCTUnwrap(harness.session.statisticsTask)
        harness.controller.invalidateHost()
        XCTAssertFalse(task.isCancelled)
        await task.value
        XCTAssertEqual(harness.session.availableStatistics, TextStatistics(text: "甲"))
        XCTAssertNil(harness.controller.captureSnapshot())
    }

    func testOutdentAfterHostTeardownLeavesSourceAndSessionTogether() {
        let source = "- a\n  - b"
        let live = IOSEditorHarness(text: source)
        live.placeCaret(at: iosUTF16(source))
        live.controller.performOutdent()
        XCTAssertNotEqual(live.textView.textStorage.string, source)
        XCTAssertEqual(live.session.text, live.textView.textStorage.string)

        let harness = IOSEditorHarness(text: source)
        harness.placeCaret(at: iosUTF16(source))
        harness.controller.invalidateHost()
        harness.controller.performOutdent()
        XCTAssertEqual(harness.textView.textStorage.string, source)
        XCTAssertEqual(harness.session.text, source)
        XCTAssertEqual(harness.session.version, 0)
    }

    func testZhuyinCompositionIsCountedOnlyAfterItIsCommitted() async throws {
        for commitsByInsertion in [false, true] {
            let harness = IOSEditorHarness(text: "")
            var applied = [TextStatistics?]()
            let counts = harness.session.$availableStatistics.dropFirst().sink { applied.append($0) }
            defer { counts.cancel() }
            harness.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0))
            harness.textView.setMarkedText("ㄓㄨ", selectedRange: NSRange(location: 2, length: 0))
            harness.textView.setMarkedText("ㄓㄨㄥ", selectedRange: NSRange(location: 3, length: 0))
            XCTAssertNotNil(harness.textView.markedTextRange)
            XCTAssertEqual(harness.session.text, "ㄓㄨㄥ")
            XCTAssertNil(harness.session.statisticsTask)
            if commitsByInsertion {
                harness.textView.insertText("中")
            } else {
                harness.textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0))
                XCTAssertNil(harness.session.statisticsTask)
                harness.textView.unmarkText()
            }
            XCTAssertNil(harness.textView.markedTextRange)
            XCTAssertEqual(harness.session.text, "中")
            let task = try XCTUnwrap(harness.session.statisticsTask)
            await task.value
            XCTAssertEqual(applied, [TextStatistics(text: "中")], "commit by insertion: \(commitsByInsertion)")
            XCTAssertEqual(
                harness.controller.captureSnapshot()?.document.availableStatistics,
                TextStatistics(text: "中")
            )
        }
    }

    func testDetachDuringCompositionCountsTheDocumentItLeaves() async throws {
        let harness = IOSEditorHarness(text: "")
        harness.textView.setMarkedText("ㄓㄨ", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNil(harness.session.statisticsTask)
        harness.controller.detach(expected: harness.identity, bindingID: harness.bindingID)
        let task = try XCTUnwrap(harness.session.statisticsTask)
        await task.value
        XCTAssertEqual(harness.session.availableStatistics, TextStatistics(text: "ㄓㄨ"))
    }

    func testOneMiBTraditionalChineseBurst() async throws {
        let paragraph = "## 草稿\n\n我們在寫一份繁體中文的技術文件，內容包含 Unicode、標點與數字 123。\n\n"
        let original = String(repeating: paragraph, count: 1_048_576 / paragraph.utf8.count)
        let harness = IOSEditorHarness(text: original)
        var applied = [TextStatistics?]()
        let counts = harness.session.$availableStatistics.dropFirst().sink { applied.append($0) }
        defer { counts.cancel() }
        harness.placeCaret(at: 0)
        var tasks = [Task<Void, Never>]()
        for _ in 0 ..< 5 {
            harness.textView.insertText("甲")
            try tasks.append(XCTUnwrap(harness.session.statisticsTask))
        }
        XCTAssertEqual(harness.session.version, 5)
        XCTAssertEqual(tasks.map(\.isCancelled), [true, true, true, true, false])
        await tasks[4].value
        XCTAssertEqual(harness.session.text, "甲甲甲甲甲" + original)
        XCTAssertEqual(applied, [TextStatistics(text: harness.session.text)])
    }

    private func binding(for session: DocumentSession,
                         identity: IOSDocumentIdentity) -> IOSSourceEditorDocumentBinding
    {
        IOSSourceEditorDocumentBinding(
            bindingID: UUID(), identity: identity, session: session, accessGeneration: 1, canWrite: true
        )
    }

    private func recordSnapshots(of controller: IOSSourceEditorController) -> SnapshotRecorder {
        let recorder = SnapshotRecorder()
        recorder.observation = controller.observe { [weak recorder] event in
            if case let .snapshotChanged(snapshot) = event { recorder?.values.append(snapshot) }
        }
        addTeardownBlock { @MainActor in recorder.observation?.cancel() }
        return recorder
    }
}

@MainActor
private final class SnapshotRecorder {
    var values = [IOSSourceEditorSnapshot]()
    var observation: (any IOSObservation)?
}
