@testable import EditorKitIOS
import MarkdownCore
import XCTest

@MainActor
final class IOSEditorStatisticsTests: XCTestCase {
    func testBurstCountsOnlyFinalEditAndPublishesIt() async throws {
        let harness = IOSEditorHarness(text: "")
        let gate = StatisticsGate()
        harness.controller.statisticsDebounce = { await gate.wait() }
        let trace = recordCounts(in: harness)
        var snapshots = [IOSSourceEditorSnapshot]()
        let observation = harness.controller.observe {
            if case let .snapshotChanged(snapshot) = $0 { snapshots.append(snapshot) }
        }
        defer { observation.cancel() }
        var requests = [Task<Void, Never>]()
        for version in 1 ... 5 {
            harness.textView.insertText("甲")
            XCTAssertEqual(harness.session.version, version)
            XCTAssertEqual(harness.session.text, String(repeating: "甲", count: version))
            try requests.append(XCTUnwrap(harness.controller.statisticsTask))
        }
        XCTAssertTrue(trace.starts.isEmpty)
        await gate.open()
        for request in requests {
            await request.value
        }
        let expected = TextStatistics(text: "甲甲甲甲甲")
        XCTAssertEqual(trace.starts, [5])
        XCTAssertEqual(harness.session.availableStatistics, expected)
        XCTAssertEqual(snapshots.last?.revision.version, 5)
        XCTAssertEqual(snapshots.last?.document.availableStatistics, expected)
    }

    func testNewEditCancelsInsideRunningCounter() async throws {
        let harness = IOSEditorHarness(text: "")
        let gate = StatisticsGate()
        let started = expectation(description: "first count entered")
        let count = harness.controller.countStatistics
        harness.controller.statisticsDebounce = {}
        harness.controller.countStatistics = { text in
            if text == "甲" {
                started.fulfill()
                await gate.wait()
                XCTAssertTrue(Task.isCancelled)
                let result = await count(text)
                XCTAssertNil(result)
                return result
            }
            return await count(text)
        }
        harness.textView.insertText("甲")
        let first = try XCTUnwrap(harness.controller.statisticsTask)
        await fulfillment(of: [started], timeout: 5)
        harness.textView.insertText("乙")
        let last = try XCTUnwrap(harness.controller.statisticsTask)
        await last.value
        await gate.open()
        await first.value
        XCTAssertEqual(harness.session.availableStatistics, TextStatistics(text: "甲乙"))
    }

    func testSwitchRejectsLateCountWithIdenticalSourceAndVersionAndReattachFinishesCount() async throws {
        let harness = IOSEditorHarness(text: "")
        let firstBinding = try XCTUnwrap(harness.controller.installation)
        let gate = StatisticsGate()
        let started = expectation(description: "first result computed")
        let count = harness.controller.countStatistics
        harness.controller.statisticsDebounce = {}
        harness.controller.countStatistics = { text in
            let result = await count(text)
            started.fulfill()
            await gate.wait()
            return result
        }
        harness.textView.insertText("甲")
        let first = try XCTUnwrap(harness.controller.statisticsTask)
        await fulfillment(of: [started], timeout: 5)

        let second = DocumentSession(text: "another document")
        let secondCounts = second.availableStatistics
        second.replaceText("甲", refreshStatistics: false)
        XCTAssertEqual(second.version, harness.session.version)
        let secondGate = StatisticsGate()
        harness.controller.statisticsDebounce = { await secondGate.wait() }
        harness.controller.countStatistics = count
        let secondBinding = IOSSourceEditorDocumentBinding(
            bindingID: UUID(), identity: IOSDocumentIdentity(rawValue: UUID()),
            session: second, accessGeneration: 1, canWrite: true
        )
        harness.controller.attach(secondBinding)
        let pending = try XCTUnwrap(harness.controller.statisticsTask)
        await gate.open()
        await first.value
        XCTAssertEqual(second.availableStatistics, secondCounts)
        XCTAssertTrue(harness.session.needsStatisticsRefresh)
        harness.controller.detach(expected: secondBinding.identity, bindingID: secondBinding.bindingID)
        await secondGate.open()
        await pending.value
        XCTAssertTrue(pending.isCancelled)
        XCTAssertEqual(second.availableStatistics, secondCounts)
        XCTAssertNil(harness.controller.captureSnapshot())

        harness.controller.attach(firstBinding)
        let resumed = try XCTUnwrap(harness.controller.statisticsTask)
        await resumed.value
        XCTAssertEqual(harness.controller.captureSnapshot()?.document.availableStatistics, TextStatistics(text: "甲"))
        XCTAssertFalse(harness.session.needsStatisticsRefresh)
    }

    func testHostTeardownCancelsPendingStatistics() async throws {
        let harness = IOSEditorHarness(text: "")
        let gate = StatisticsGate()
        harness.controller.statisticsDebounce = { await gate.wait() }
        let trace = recordCounts(in: harness)
        harness.textView.insertText("甲")
        let pending = try XCTUnwrap(harness.controller.statisticsTask)
        harness.controller.invalidateHost()
        await gate.open()
        await pending.value
        XCTAssertTrue(pending.isCancelled)
        XCTAssertTrue(trace.starts.isEmpty)
        XCTAssertNil(harness.controller.captureSnapshot())
    }

    func testRelocationBeforePublicationFinishesAtNewRevision() async throws {
        let harness = IOSEditorHarness(text: "")
        let gate = StatisticsGate()
        harness.controller.statisticsDebounce = { await gate.wait() }
        harness.textView.insertText("甲")
        let first = try XCTUnwrap(harness.controller.statisticsTask)
        harness.session.relocate(to: URL(fileURLWithPath: "/tmp/moved.mdx"))

        let nextGate = StatisticsGate()
        harness.controller.statisticsDebounce = { await nextGate.wait() }
        await gate.open()
        await first.value
        let retry = try XCTUnwrap(harness.controller.statisticsTask)
        XCTAssertEqual(harness.session.availableStatistics, TextStatistics(text: ""))
        await nextGate.open()
        await retry.value
        let snapshot = try XCTUnwrap(harness.controller.captureSnapshot())
        XCTAssertEqual(snapshot.revision.version, 2)
        XCTAssertEqual(snapshot.document.availableStatistics, TextStatistics(text: "甲"))
    }

    func testOneMiBTraditionalChineseBurst() async throws {
        let paragraph = "## 草稿\n\n我們在寫一份繁體中文的技術文件，內容包含 Unicode、標點與數字 123。\n\n"
        let original = String(repeating: paragraph, count: 1_048_576 / paragraph.utf8.count)
        let harness = IOSEditorHarness(text: original)
        let trace = recordCounts(in: harness)
        harness.placeCaret(at: 0)
        var requests = [Task<Void, Never>]()
        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0 ..< 5 {
            harness.textView.insertText("甲")
            try requests.append(XCTUnwrap(harness.controller.statisticsTask))
        }
        let insertion = started.duration(to: clock.now)
        XCTAssertEqual(harness.session.version, 5)
        for request in requests {
            await request.value
        }
        XCTAssertEqual(harness.session.text, "甲甲甲甲甲" + original)
        let expected = TextStatistics(text: harness.session.text)
        XCTAssertEqual(harness.session.availableStatistics, expected)
        XCTAssertEqual(trace.starts, [5])
        XCTAssertEqual(trace.stale, 0)
        print("iOS burst: bytes=\(original.utf8.count) starts=\(trace.starts) stale=\(trace.stale) " +
            "words=\(expected.wordCount) fiveInserts=\(insertion)")
    }

    private func recordCounts(in harness: IOSEditorHarness) -> StatisticsTrace {
        let trace = StatisticsTrace()
        let count = harness.controller.countStatistics
        harness.controller.countStatistics = { [session = harness.session] text in
            let version = text.prefix(while: { $0 == "甲" }).count
            await trace.start(version)
            let result = await count(text)
            await trace.finish(version, session: session)
            return result
        }
        return trace
    }
}

@MainActor
private final class StatisticsTrace {
    var starts = [Int]()
    var stale = 0

    func start(_ version: Int) {
        starts.append(version)
    }

    func finish(_ version: Int, session: DocumentSession) {
        if session.version != version { stale += 1 }
    }
}

private actor StatisticsGate {
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}
