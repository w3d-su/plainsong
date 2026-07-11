import AppKit
import CoreGraphics
@testable import EditorKit
import XCTest

@MainActor
final class WYSIWYGActualIMEEventGateTests: XCTestCase {
    func testActualIMEEventPostingAccessIsGranted() throws {
        try Self.requireActualIMEOptIn()
        XCTAssertTrue(
            Self.hasOrRequestsEventPostingAccess(),
            Self.eventPostingAccessRecovery
        )
    }

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

    func testImageBoundaryFixturesTargetReadyAndLoadingThumbnailPresentation() throws {
        let scenarios = ActualIMEFoldBoundaryScenario.imageBoundaryCases
        XCTAssertEqual(scenarios.count, 4)
        XCTAssertEqual(
            scenarios.filter { $0.imagePresentationState == .readyThumbnail }.count,
            2
        )
        XCTAssertEqual(
            scenarios.filter { $0.imagePresentationState == .loadingPlaceholder }.count,
            2
        )

        let source = actualIMEImageGateSource
        let imageRange = (source as NSString).range(of: actualIMEImageGateLiteral)
        for scenario in scenarios {
            XCTAssertEqual(scenario.developmentPresentation, .inlineFoldRevealWithLinkFolding)
            XCTAssertTrue(
                scenario.insertionLocation == imageRange.location
                    || scenario.insertionLocation == NSMaxRange(imageRange)
            )
            let highlighted = MarkdownSyntaxHighlighter().highlight(
                scenario.source,
                fileKind: .markdown,
                visibleRange: NSRange(location: 0, length: (scenario.source as NSString).length),
                developmentPresentation: scenario.developmentPresentation,
                selection: NSRange(location: (scenario.source as NSString).length, length: 0)
            )
            let imageRegion = try XCTUnwrap(highlighted.foldPlan?.imageRegions.first)
            XCTAssertEqual(highlighted.foldPlan?.imageRegions.count, 1)
            XCTAssertEqual(imageRegion.sourceRange, imageRange)
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
        try Self.requireActualIMEEventPostingAccess()
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
        try Self.requireActualIMEEventPostingAccess()
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

    func testActualZhuyinEventStreamAtImageBoundaries() throws {
        try Self.requireActualIMEOptIn()
        try Self.requireActualIMEEventPostingAccess()
        let inputSource = try XCTUnwrap(
            ActualIMEInputSource.enabled(matching: .zhuyin),
            "Expected enabled macOS Traditional Chinese Zhuyin input source"
        )

        print("Actual IME source: \(inputSource.summary)")
        try ActualIMEEventHarness.withSelectedInputSource(inputSource) { harness in
            try harness.assertEventStream(
                script: .zhuyin,
                scenarios: ActualIMEFoldBoundaryScenario.imageBoundaryCases
            )
        }
    }

    func testActualPinyinEventStreamAtFoldBoundariesWhenEnabled() throws {
        try Self.requireActualIMEOptIn()
        try Self.requireActualIMEEventPostingAccess()
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
        try Self.requireActualIMEEventPostingAccess()
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

    func testActualPinyinEventStreamAtImageBoundariesWhenEnabled() throws {
        try Self.requireActualIMEOptIn()
        try Self.requireActualIMEEventPostingAccess()
        guard let inputSource = ActualIMEInputSource.enabled(matching: .pinyin) else {
            let installedPinyin = ActualIMEInputSource.installed(matching: .pinyin)
                .map(\.summary)
                .joined(separator: ", ")
            throw XCTSkip("""
            No enabled/selectable macOS Pinyin input method. Installed matches: \
            \(installedPinyin.isEmpty ? "none" : installedPinyin). Enable Pinyin in \
            System Settings > Keyboard > Text Input > Edit > + > Chinese, then rerun \
            PLAINSONG_RUN_ACTUAL_IME=1 swift test --filter \
            WYSIWYGActualIMEEventGateTests/testActualPinyinEventStreamAtImageBoundariesWhenEnabled
            """)
        }

        print("Actual IME source: \(inputSource.summary)")
        try ActualIMEEventHarness.withSelectedInputSource(inputSource) { harness in
            try harness.assertEventStream(
                script: .pinyin,
                scenarios: ActualIMEFoldBoundaryScenario.imageBoundaryCases
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

    private static func requireActualIMEEventPostingAccess() throws {
        guard hasOrRequestsEventPostingAccess() else {
            throw XCTSkip(eventPostingAccessRecovery)
        }
    }

    private static func hasOrRequestsEventPostingAccess() -> Bool {
        CGPreflightPostEventAccess() || CGRequestPostEventAccess()
    }

    private static let eventPostingAccessRecovery = """
    The actual-IME harness cannot synthesize keyboard events. Grant Accessibility event-posting \
    access to the terminal app that launched `swift test` in System Settings > Privacy & Security \
    > Accessibility, quit and reopen that terminal app, then rerun the opt-in gate. L5 remains open.
    """

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
