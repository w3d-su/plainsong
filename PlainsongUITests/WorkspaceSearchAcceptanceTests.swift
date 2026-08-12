import AppKit
import XCTest

@MainActor
final class WorkspaceSearchAcceptanceTests: XCTestCase, @unchecked Sendable {
    private var app: XCUIApplication!
    private var workspaceWindow: XCUIElement!
    private var ownedPasteboard = EditorFindOwnedPasteboard()
    private var shortcutInputSource = EditorFindSyntheticShortcutInputSource()
    private var selectedASCIISourceIdentifiers = Set<String>()

    private func launchApplication() {
        continueAfterFailure = false
        ownedPasteboard = EditorFindOwnedPasteboard()
        shortcutInputSource = EditorFindSyntheticShortcutInputSource()
        selectedASCIISourceIdentifiers = []
        app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["PLAINSONG_DEBUG_WORKSPACE_SEARCH_FIXTURE"] =
            "ws4a-\(UUID().uuidString)"
        app.launch()
        app.activate()

        addTeardownBlock {
            await self.terminateApplication()
        }

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let modeIdentifier = "plainsong.workspaceSearch.mode"
        XCTAssertTrue(
            app.descendants(matching: .any)[modeIdentifier].waitForExistence(timeout: 10),
            "The isolated workspace fixture did not finish opening"
        )
        workspaceWindow = app.windows
            .containing(.any, identifier: modeIdentifier)
            .allElementsBoundByAccessibilityElement
            .first(where: \.isHittable)
        XCTAssertNotNil(workspaceWindow, "The fixture workspace has no hittable window")
    }

    private func makeFixtureWindowKey() {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(workspaceWindow.waitForExistence(timeout: 5))
        // Explicitly click the title bar: clicking content in a foreground-but-not-key window
        // can be delivered by XCUITest without AppKit promoting that window first.
        workspaceWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        app.activate()
        workspaceWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        editor.click()
        waitForKeyboardFocus(editor)
    }

    private func terminateApplication() {
        var inputSourceEvents = [attemptInputSourceRestoration(
            phase: "before app termination"
        )]
        var pasteboardEvents = [attemptPasteboardRestoration(
            phase: "before app termination"
        )]
        app.terminate()
        let didTerminate = app.wait(for: .notRunning, timeout: 5)

        if shortcutInputSource.hasPendingRestoration {
            inputSourceEvents.append(attemptInputSourceRestoration(
                phase: "after app termination retry"
            ))
        }
        if ownedPasteboard.hasPendingRestoration {
            pasteboardEvents.append(attemptPasteboardRestoration(
                phase: "after app termination retry"
            ))
        }

        print(
            "WS4A synthetic ASCII input source(s): "
                + selectedASCIISourceIdentifiers.sorted().joined(separator: ", ")
        )
        print("WS4A input-source restoration: " + inputSourceEvents.joined(separator: "; "))
        print("WS4A pasteboard restoration: " + pasteboardEvents.joined(separator: "; "))
        XCTAssertFalse(
            shortcutInputSource.hasPendingRestoration,
            "Input-source restoration still failed after the post-termination retry"
        )
        XCTAssertFalse(
            ownedPasteboard.hasPendingRestoration,
            "General-pasteboard restoration still failed after the post-termination retry"
        )
        XCTAssertTrue(didTerminate, "The fixture app did not terminate before teardown finished")

        app = nil
        workspaceWindow = nil
    }

    func testShortcutKeyboardActivationAndEscapeTransitions() throws {
        launchApplication()
        let queryField = try openSearchWithShortcut()
        try enterCJKQuery(in: queryField)

        let first = resultRow(relativePath: "a-overview.md")
        let target = resultRow(relativePath: "posts/b-target.mdx")
        let last = resultRow(relativePath: "z-last.md")
        assertGroupedResultsExist()

        queryField.typeKey(.downArrow, modifierFlags: [])
        waitForReducerReceipt(sequence: 1, action: "selectFirst")
        waitForSelected(first)

        app.typeKey(.upArrow, modifierFlags: [])
        waitForReducerReceipt(sequence: 2, action: "moveUp")
        waitForSelected(first)

        app.typeKey(.downArrow, modifierFlags: [])
        waitForReducerReceipt(sequence: 3, action: "moveDown")
        waitForSelected(target)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForReducerReceipt(sequence: 4, action: "moveDown")
        waitForSelected(last)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForReducerReceipt(sequence: 5, action: "moveDown")
        waitForSelected(last)
        app.typeKey(.upArrow, modifierFlags: [])
        waitForReducerReceipt(sequence: 6, action: "moveUp")
        waitForSelected(target)

        app.typeKey(.return, modifierFlags: [])
        waitForValue(
            "b-target.mdx",
            of: workspaceWindow.staticTexts["plainsong.editor.fileName"],
            description: "activated file name"
        )
        waitForLabel(
            "Editor UTF-16 selection 10:2",
            of: workspaceWindow.descendants(matching: .any)[
                "plainsong.debug.editor.selectedRange"
            ],
            description: "native editor UTF-16 selected range"
        )
        waitForLabel(
            "Workspace search activation 1 results",
            of: workspaceWindow.descendants(matching: .any)[
                "plainsong.debug.workspaceSearch.activation"
            ],
            description: "this activation completing its results-focus restoration"
        )

        // Deliberately do not wait for the first Escape's forced query-focus confirmation
        // loop. The second Escape must supersede that in-flight intent and leave the editor
        // focused rather than allowing Search to reclaim first responder.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        waitForLabel(
            "Workspace search escape editor",
            of: workspaceWindow.descendants(matching: .any)[
                "plainsong.debug.workspaceSearch.escape"
            ],
            description: "results→query→editor Escape event routing"
        )
        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        waitForKeyboardFocus(editor)
        assertQueryAndResultsRemain(queryField: queryField, target: target)
    }

    func testClickThenArrowKeysUseSearchSelection() throws {
        launchApplication()
        let queryField = try openSearchWithShortcut()
        try enterCJKQuery(in: queryField)

        let first = resultRow(relativePath: "a-overview.md")
        let target = resultRow(relativePath: "posts/b-target.mdx")
        XCTAssertTrue(target.waitForExistence(timeout: 10))

        target.click()
        waitForSelected(target)
        let reducerProbe = workspaceWindow.descendants(matching: .any)[
            "plainsong.debug.workspaceSearch.reducerEvent"
        ]
        XCTAssertTrue(reducerProbe.waitForExistence(timeout: 5))
        app.typeKey(.upArrow, modifierFlags: [])
        waitForReducerReceipt(sequence: 1, action: "moveUp", probe: reducerProbe)
        waitForSelected(first)
        app.typeKey(.upArrow, modifierFlags: [])
        waitForReducerReceipt(sequence: 2, action: "moveUp", probe: reducerProbe)
        waitForSelected(first)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForReducerReceipt(sequence: 3, action: "moveDown", probe: reducerProbe)
        waitForSelected(target)
    }

    private func openSearchWithShortcut() throws -> XCUIElement {
        makeFixtureWindowKey()
        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        try typeSyntheticTextKey(
            "f",
            modifierFlags: [.command, .shift],
            on: editor
        )
        let queryField = workspaceWindow.textFields["plainsong.workspaceSearch.queryField"]
        XCTAssertTrue(queryField.waitForExistence(timeout: 5))
        let focusProbe = workspaceWindow.descendants(matching: .any)[
            "plainsong.debug.workspaceSearch.focusSurface"
        ]
        waitForLabel(
            "Workspace search focus query",
            of: focusProbe,
            description: "query-field routing after shortcut"
        )
        waitForKeyboardFocus(queryField)
        try typeSyntheticTextKey("x", modifierFlags: [], on: app)
        waitForValue("x", of: queryField, description: "shortcut-focused query field")
        return queryField
    }

    private func enterCJKQuery(in queryField: XCUIElement) throws {
        queryField.click()
        try typeSyntheticTextKey("a", modifierFlags: .command, on: queryField)
        try ownedPasteboard.writeString("搜尋")
        try typeSyntheticTextKey("v", modifierFlags: .command, on: app)
        waitForValue("搜尋", of: queryField, description: "CJK query")
    }

    /// XCUI's textual key API is interpreted through the selected input source. Each injection
    /// is scoped to an enabled, select-capable ASCII source and restores the exact prior source
    /// immediately. This remains synthetic UI-automation evidence, not physical-keyboard evidence.
    private func typeSyntheticTextKey(
        _ key: String,
        modifierFlags: XCUIElement.KeyModifierFlags,
        on element: XCUIElement
    ) throws {
        do {
            let identifier = try shortcutInputSource.withASCIICapableInputSource {
                element.typeKey(
                    XCUIKeyboardKey(rawValue: key),
                    modifierFlags: modifierFlags
                )
            }
            selectedASCIISourceIdentifiers.insert(identifier)
        } catch let error as EditorFindSyntheticShortcutInputSource.InputSourceError {
            switch error {
            case .noEligibleInputSource:
                throw XCTSkip(
                    "This runner has no enabled, select-capable ASCII input source"
                )
            case let .couldNotUseEligibleInputSources(failures):
                throw XCTSkip(
                    "This runner could not select/read back an eligible ASCII input source: "
                        + failures.joined(separator: "; ")
                )
            case let .currentSourceChangedBeforeSelection(identifier),
                 let .currentSourceChangedDuringShortcut(identifier):
                throw XCTSkip(
                    "The runner's input source changed externally during synthetic input: "
                        + identifier
                )
            default:
                throw error
            }
        }
    }

    private func attemptInputSourceRestoration(phase: String) -> String {
        do {
            let outcome = try shortcutInputSource.restorePendingSelectionIfOwned()
            return "\(phase): \(outcome)"
        } catch {
            return "\(phase) failed: \(error)"
        }
    }

    private func attemptPasteboardRestoration(phase: String) -> String {
        do {
            let outcome = try ownedPasteboard.restoreIfStillOwned()
            return "\(phase): \(outcome)"
        } catch {
            return "\(phase) failed: \(error)"
        }
    }

    private func assertGroupedResultsExist() {
        // Two visible file sections prove grouping without requiring SwiftUI's lazy List to
        // materialize the off-screen final section before keyboard navigation reaches it.
        for path in ["a-overview.md", "posts/b-target.mdx"] {
            let section = element(withIdentifierPrefix: sectionIdentifierPrefix(relativePath: path))
            XCTAssertTrue(section.waitForExistence(timeout: 10), "Missing grouped section for \(path)")
        }
    }

    private func assertQueryAndResultsRemain(
        queryField: XCUIElement,
        target: XCUIElement
    ) {
        XCTAssertEqual(queryField.value as? String, "搜尋")
        XCTAssertTrue(target.exists)
    }

    private func resultRow(relativePath: String) -> XCUIElement {
        element(withIdentifierPrefix: rowIdentifierPrefix(relativePath: relativePath))
    }

    private func element(withIdentifierPrefix prefix: String) -> XCUIElement {
        workspaceWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    private func waitForSelected(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: timeout), .completed)
    }

    private func waitForKeyboardFocus(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: timeout), .completed)
    }

    private func waitForValue(
        _ expectedValue: String,
        of element: XCUIElement,
        description: String,
        timeout: TimeInterval = 10
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(description)")
        let value = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [value], timeout: timeout),
            .completed,
            "Unexpected \(description): \(String(describing: element.value))"
        )
    }

    private func waitForLabel(
        _ expectedLabel: String,
        of element: XCUIElement,
        description: String,
        timeout: TimeInterval = 10
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(description)")
        let label = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expectedLabel),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [label], timeout: timeout),
            .completed,
            "Unexpected \(description): \(element.label)"
        )
    }

    private func waitForReducerReceipt(
        sequence: UInt64,
        action: String,
        probe: XCUIElement? = nil
    ) {
        let reducerProbe = probe ?? workspaceWindow.descendants(matching: .any)[
            "plainsong.debug.workspaceSearch.reducerEvent"
        ]
        waitForLabel(
            "Workspace search reducer \(sequence) \(action)",
            of: reducerProbe,
            description: "reducer receipt \(sequence) for \(action)"
        )
    }

    private func rowIdentifierPrefix(relativePath: String) -> String {
        "plainsong.workspaceSearch.row.\(utf8Hex(relativePath))."
    }

    private func sectionIdentifierPrefix(relativePath: String) -> String {
        "plainsong.workspaceSearch.section.\(utf8Hex(relativePath))."
    }

    private func utf8Hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
