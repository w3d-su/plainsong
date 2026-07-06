import AppKit
@testable import EditorKit
import XCTest

@MainActor
final class WYSIWYGActualIMEEventGateTests: XCTestCase {
    func testLinkBoundaryFixturesTargetLinkFoldingPresentation() throws {
        XCTAssertEqual(ActualIMEFoldBoundaryScenario.linkBoundaryCases.count, 3)

        for scenario in ActualIMEFoldBoundaryScenario.linkBoundaryCases {
            XCTAssertEqual(scenario.developmentPresentation, .inlineFoldRevealWithLinkFolding)
            let highlighted = MarkdownSyntaxHighlighter().highlight(
                scenario.source,
                fileKind: .markdown,
                visibleRange: NSRange(location: 0, length: (scenario.source as NSString).length),
                developmentPresentation: scenario.developmentPresentation,
                selection: NSRange(location: (scenario.source as NSString).length, length: 0)
            )
            let links = try XCTUnwrap(highlighted.foldPlan).regions.filter { $0.kind == .link }
            let link = try XCTUnwrap(links.first)
            XCTAssertEqual(links.count, 1)
            XCTAssertFalse(link.isRevealed)
            XCTAssertEqual(link.foldRanges, scenario.foldedRanges)
        }
    }

    func testMarkedTextSelectionKeysAreReservedForInputContextOnlyWhileComposing() throws {
        let returnEvent = try Self.keyEvent(characters: "\r", keyCode: 36)
        let spaceEvent = try Self.keyEvent(characters: " ", keyCode: 49)
        let enterEvent = try Self.keyEvent(characters: "\r", keyCode: 76)
        let letterEvent = try Self.keyEvent(characters: "a", keyCode: 0)
        let commandReturnEvent = try Self.keyEvent(characters: "\r", modifierFlags: .command, keyCode: 36)

        XCTAssertTrue(MarkdownSTTextView.shouldReserveMarkedTextKeyForInputContext(returnEvent, hasMarkedText: true))
        XCTAssertTrue(MarkdownSTTextView.shouldReserveMarkedTextKeyForInputContext(spaceEvent, hasMarkedText: true))
        XCTAssertTrue(MarkdownSTTextView.shouldReserveMarkedTextKeyForInputContext(enterEvent, hasMarkedText: true))
        XCTAssertFalse(MarkdownSTTextView.shouldReserveMarkedTextKeyForInputContext(letterEvent, hasMarkedText: true))
        XCTAssertFalse(MarkdownSTTextView.shouldReserveMarkedTextKeyForInputContext(returnEvent, hasMarkedText: false))
        XCTAssertFalse(MarkdownSTTextView.shouldReserveMarkedTextKeyForInputContext(
            commandReturnEvent,
            hasMarkedText: true
        ))
    }

    func testActualZhuyinEventStreamAtFoldBoundaries() throws {
        try Self.requireActualIMEOptIn()
        let inputSource = try XCTUnwrap(
            ActualIMEInputSource.enabled(matching: .zhuyin),
            "Expected enabled macOS Traditional Chinese Zhuyin input source"
        )

        print("Actual IME source: \(inputSource.summary)")
        try ActualIMEEventHarness.withSelectedInputSource(inputSource) { harness in
            try harness.assertEventStream(
                script: .zhuyin,
                scenarios: ActualIMEFoldBoundaryScenario.allCases
            )
        }
    }

    func testActualZhuyinEventStreamAtLinkBoundaries() throws {
        try Self.requireActualIMEOptIn()
        let inputSource = try XCTUnwrap(
            ActualIMEInputSource.enabled(matching: .zhuyin),
            "Expected enabled macOS Traditional Chinese Zhuyin input source"
        )

        print("Actual IME source: \(inputSource.summary)")
        try ActualIMEEventHarness.withSelectedInputSource(inputSource) { harness in
            try harness.assertEventStream(
                script: .zhuyin,
                scenarios: ActualIMEFoldBoundaryScenario.linkBoundaryCases
            )
        }
    }

    func testActualPinyinEventStreamAtFoldBoundariesWhenEnabled() throws {
        try Self.requireActualIMEOptIn()
        guard let inputSource = ActualIMEInputSource.enabled(matching: .pinyin) else {
            let installedPinyin = ActualIMEInputSource.installed(matching: .pinyin)
                .map(\.summary)
                .joined(separator: ", ")
            throw XCTSkip("""
            No enabled/selectable macOS Pinyin input method. Installed matches: \
            \(installedPinyin.isEmpty ? "none" : installedPinyin). Enable Pinyin in \
            System Settings > Keyboard > Text Input > Edit > + > Chinese, then rerun \
            PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter \
            WYSIWYGActualIMEEventGateTests/testActualPinyinEventStreamAtFoldBoundariesWhenEnabled
            """)
        }

        print("Actual IME source: \(inputSource.summary)")
        try ActualIMEEventHarness.withSelectedInputSource(inputSource) { harness in
            try harness.assertEventStream(
                script: .pinyin,
                scenarios: ActualIMEFoldBoundaryScenario.allCases
            )
        }
    }

    func testActualPinyinEventStreamAtLinkBoundariesWhenEnabled() throws {
        try Self.requireActualIMEOptIn()
        guard let inputSource = ActualIMEInputSource.enabled(matching: .pinyin) else {
            let installedPinyin = ActualIMEInputSource.installed(matching: .pinyin)
                .map(\.summary)
                .joined(separator: ", ")
            throw XCTSkip("""
            No enabled/selectable macOS Pinyin input method. Installed matches: \
            \(installedPinyin.isEmpty ? "none" : installedPinyin). Enable Pinyin in \
            System Settings > Keyboard > Text Input > Edit > + > Chinese, then rerun \
            PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter \
            WYSIWYGActualIMEEventGateTests/testActualPinyinEventStreamAtLinkBoundariesWhenEnabled
            """)
        }

        print("Actual IME source: \(inputSource.summary)")
        try ActualIMEEventHarness.withSelectedInputSource(inputSource) { harness in
            try harness.assertEventStream(
                script: .pinyin,
                scenarios: ActualIMEFoldBoundaryScenario.linkBoundaryCases
            )
        }
    }

    private static func requireActualIMEOptIn() throws {
        guard ProcessInfo.processInfo.environment["PLAINSONG_RUN_ACTUAL_IME"] == "1" else {
            throw XCTSkip("""
            Actual macOS IME event-stream gate is opt-in. Rerun with \
            PLAINSONG_RUN_ACTUAL_IME=1 to open a focused AppKit editor window and \
            send CGEvent key presses through the selected TIS input source.
            """)
        }
    }

    private static func keyEvent(
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = [],
        keyCode: UInt16
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
