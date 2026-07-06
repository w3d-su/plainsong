import AppKit
import Carbon
import CoreGraphics
@testable import EditorKit
import STTextView
import XCTest

@MainActor
final class ActualIMEEventHarness {
    private let app: NSApplication

    private init(app: NSApplication) {
        self.app = app
        app.setActivationPolicy(.regular)
    }

    static func withSelectedInputSource(
        _ inputSource: ActualIMEInputSource,
        _ body: (ActualIMEEventHarness) throws -> Void
    ) throws {
        let originalInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let status = TISSelectInputSource(inputSource.source)
        XCTAssertEqual(status, noErr, "Unable to select \(inputSource.summary)")
        defer {
            if ActualIMEInputSource.identifier(of: originalInputSource) != inputSource.identifier {
                TISSelectInputSource(originalInputSource)
            }
        }

        try body(ActualIMEEventHarness(app: .shared))
    }

    func assertEventStream(
        script: ActualIMEScript,
        scenarios: [ActualIMEFoldBoundaryScenario],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = makeFocusedEditorWindow()
        defer {
            fixture.textView.inputContext?.discardMarkedText()
            pumpRunLoop(for: 0.5)
        }

        for scenario in scenarios {
            try assertEventStream(
                script: script,
                scenario: scenario,
                in: fixture.textView,
                file: file,
                line: line
            )
            print("Actual IME scenario passed: \(script.name) — \(scenario.name)")
        }
    }

    // swiftlint:disable:next function_body_length
    private func assertEventStream(
        script: ActualIMEScript,
        scenario: ActualIMEFoldBoundaryScenario,
        in textView: MarkdownSTTextView,
        file: StaticString,
        line: UInt
    ) throws {
        textView.inputContext?.discardMarkedText()
        textView.text = scenario.source
        textView.textSelection = NSRange(location: scenario.insertionLocation, length: 0)
        XCTAssertTrue(
            applyProductionPresentation(
                scenario.source,
                selection: NSRange(location: (scenario.source as NSString).length, length: 0),
                revision: 0,
                developmentPresentation: scenario.developmentPresentation,
                to: textView
            ),
            "\(script.name) \(scenario.name)",
            file: file,
            line: line
        )
        assertFoldedRangesCarryProductionAttributes(
            in: textView,
            ranges: scenario.foldedRanges,
            script: script,
            scenario: scenario,
            file: file,
            line: line
        )

        for step in script.compositionSteps {
            press(step.key)
            let currentText = Self.text(in: textView)
            XCTAssertTrue(
                step.acceptableInsertedTexts.containsInsertedText(
                    in: currentText,
                    source: scenario.source,
                    at: scenario.insertionLocation
                ),
                "\(script.name) \(scenario.name) after \(step.key.name): \(currentText)",
                file: file,
                line: line
            )
            assertActiveMarkedText(
                in: textView,
                acceptableInsertedTexts: step.acceptableInsertedTexts,
                script: script,
                scenario: scenario,
                file: file,
                line: line
            )
            assertFoldApplySkippedDuringMarkedText(
                in: textView,
                currentText: currentText,
                script: script,
                scenario: scenario,
                file: file,
                line: line
            )
        }

        let committedText = try commitMarkedText(
            script: script,
            scenario: scenario,
            in: textView,
            file: file,
            line: line
        )
        XCTAssertFalse(textView.hasMarkedText(), "\(script.name) \(scenario.name)", file: file, line: line)

        let committedInsertion = try XCTUnwrap(
            script.acceptableCommittedTexts.insertedText(
                in: committedText,
                source: scenario.source,
                at: scenario.insertionLocation
            ),
            "\(script.name) \(scenario.name) committed unexpected text: \(committedText)",
            file: file,
            line: line
        )
        let expectedSelection = NSRange(
            location: scenario.insertionLocation + committedInsertion.utf16.count,
            length: 0
        )
        XCTAssertEqual(
            textView.selectedRange(),
            expectedSelection,
            "\(script.name) \(scenario.name)",
            file: file,
            line: line
        )

        let reapplySelection = NSRange(location: (committedText as NSString).length, length: 0)
        let didReapplyPresentation = applyProductionPresentation(
            committedText,
            selection: reapplySelection,
            revision: 100,
            developmentPresentation: scenario.developmentPresentation,
            to: textView
        )
        XCTAssertTrue(didReapplyPresentation, "\(script.name) \(scenario.name)", file: file, line: line)
        XCTAssertEqual(
            Self.text(in: textView),
            committedText,
            "\(script.name) \(scenario.name)",
            file: file,
            line: line
        )
        if scenario.verifiesLinkFoldAfterCommit {
            assertLinkFoldAttributesReappliedAfterCommit(
                in: textView,
                committedText: committedText,
                presentationSelection: reapplySelection,
                script: script,
                scenario: scenario,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            textView.selectedRange(),
            expectedSelection,
            "\(script.name) \(scenario.name)",
            file: file,
            line: line
        )
    }
}

@MainActor
private extension ActualIMEEventHarness {
    private func commitMarkedText(
        script: ActualIMEScript,
        scenario: ActualIMEFoldBoundaryScenario,
        in textView: STTextView,
        file: StaticString,
        line: UInt
    ) throws -> String {
        for key in script.commitKeys {
            press(key)
            let currentText = Self.text(in: textView)
            if textView.hasMarkedText() {
                XCTAssertTrue(
                    script.acceptableActiveCommitTexts.containsInsertedText(
                        in: currentText,
                        source: scenario.source,
                        at: scenario.insertionLocation
                    ),
                    "\(script.name) \(scenario.name) during commit \(key.name): \(currentText)",
                    file: file,
                    line: line
                )
                assertActiveMarkedText(
                    in: textView,
                    acceptableInsertedTexts: script.acceptableActiveCommitTexts,
                    script: script,
                    scenario: scenario,
                    file: file,
                    line: line
                )
                assertFoldApplySkippedDuringMarkedText(
                    in: textView,
                    currentText: currentText,
                    script: script,
                    scenario: scenario,
                    file: file,
                    line: line
                )
            } else {
                return currentText
            }
        }

        let commitKeyNames = script.commitKeys.map(\.name).joined(separator: ", ")
        XCTFail("\(script.name) \(scenario.name) did not commit after \(commitKeyNames)", file: file, line: line)
        return Self.text(in: textView)
    }

    private func makeFocusedEditorWindow() -> (window: NSWindow, textView: MarkdownSTTextView) {
        let frame = NSRect(x: 80, y: 80, width: 720, height: 280)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        guard let textView = scrollView.documentView as? MarkdownSTTextView else {
            fatalError("Expected MarkdownSTTextView.scrollableTextView() to contain MarkdownSTTextView")
        }

        textView.isEditable = true
        textView.isSelectable = true
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.setWYSIWYGZeroWidthFoldingEnabled(true)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        window.makeKey()
        app.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)
        pumpRunLoop(for: 0.4)
        return (window, textView)
    }

    private func press(_ key: ActualIMEKey) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: key.keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: key.keyCode, keyDown: false)
        let processID = pid_t(ProcessInfo.processInfo.processIdentifier)

        keyDown?.postToPid(processID)
        pumpRunLoop(for: 0.08)
        keyUp?.postToPid(processID)
        pumpRunLoop(for: 0.4)
    }

    private func pumpRunLoop(for seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if let event = app.nextEvent(
                matching: .any,
                until: Date(timeIntervalSinceNow: 0.01),
                inMode: .default,
                dequeue: true
            ) {
                app.sendEvent(event)
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }
}
