import AppKit
import XCTest

@MainActor
final class EditorFindAcceptanceTests: XCTestCase, @unchecked Sendable {
    static let cleanupReceiptType = NSPasteboard.PasteboardType(
        "app.plainsong.editor.debug.editor-find-cleanup"
    )
    static let cleanupRequestType = NSPasteboard.PasteboardType(
        "app.plainsong.editor.debug.editor-find-cleanup-request"
    )

    var app: XCUIApplication!
    var workspaceWindow: XCUIElement!
    var ownedPasteboard = EditorFindOwnedPasteboard()
    var shortcutInputSource = EditorFindSyntheticShortcutInputSource()
    var fixtureIdentifier = ""
    var cleanupToken = ""
    var selectedASCIISourceIdentifiers = Set<String>()

    func testRepeatedCommandFRefocusesSelectsAllAndLeavesBarOpen() throws {
        launchApplication()
        let queryField = try openFindWithShortcut()
        assertStableFindChromeExists(queryField: queryField)
        try paste("needle")
        waitForValue("needle", of: queryField, description: "initial find query")
        XCTAssertTrue(
            findElement("plainsong.editorFind.matchCounter").waitForExistence(timeout: 10),
            "The launched app did not expose the active-query match counter"
        )

        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        editor.click()
        waitForKeyboardFocus(editor)
        waitForKeyboardBlur(queryField)

        let findBar = findElement("plainsong.editorFind.bar")
        try pressCommandF {
            XCTAssertTrue(
                findBar.exists,
                "The find bar must already be open immediately before repeated Command-F"
            )
            XCTAssertEqual(
                queryField.value as? String,
                "needle",
                "The retained query must still be needle immediately before repeated Command-F"
            )
        }
        waitForKeyboardFocus(queryField)
        waitForValue(
            "needle",
            of: queryField,
            description: "retained query after repeated Command-F refocus"
        )
        try paste("q")

        waitForValue(
            "q",
            of: queryField,
            description: "replacement query after repeated Command-F select-all"
        )
        XCTAssertTrue(
            findElement("plainsong.editorFind.bar").exists,
            "Repeated Command-F must not close the find bar"
        )
    }

    func testExactAndTruncatedCountersAreObservablyDistinct() throws {
        launchApplication()
        let queryField = try openFindWithShortcut()
        let counter = findElement("plainsong.editorFind.matchCounter")
        let truncated = findElement("plainsong.editorFind.truncated")

        try paste("needle")
        waitForValue("1 / 3", of: counter, description: "exact match counter")
        XCTAssertFalse(
            truncated.exists,
            "An exact match total must not expose the truncated-state indicator"
        )

        try typeCommandKey("a", on: queryField)
        try paste("x")
        waitForValue("x", of: queryField, description: "overflow query")
        waitForValueSuffix(
            " / 10000+",
            of: counter,
            description: "truncated match counter"
        )
        waitForValue(
            "Results truncated at match ceiling",
            of: truncated,
            description: "non-color-only truncated-state indicator"
        )
    }
}

extension EditorFindAcceptanceTests {
    func launchApplication() {
        continueAfterFailure = false
        ownedPasteboard = EditorFindOwnedPasteboard()
        shortcutInputSource = EditorFindSyntheticShortcutInputSource()
        fixtureIdentifier = "f9-\(UUID().uuidString)"
        cleanupToken = UUID().uuidString
        app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["PLAINSONG_DEBUG_EDITOR_FIND_FIXTURE"] =
            fixtureIdentifier
        app.launchEnvironment["PLAINSONG_DEBUG_EDITOR_FIND_CLEANUP_TOKEN"] =
            cleanupToken

        addTeardownBlock {
            await self.terminateApplication()
        }

        app.launch()
        app.activate()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let fileNameIdentifier = "plainsong.editor.fileName"
        let fileName = app.staticTexts[fileNameIdentifier]
        waitForValue(
            "editor-find.md",
            of: fileName,
            description: "isolated editor-find fixture file"
        )
        workspaceWindow = app.windows
            .containing(.staticText, identifier: fileNameIdentifier)
            .allElementsBoundByAccessibilityElement
            .first(where: \.isHittable)
        XCTAssertNotNil(workspaceWindow, "The fixture workspace has no hittable window")
        print("F9 fixture opened: \(fixtureIdentifier)")
        makeFixtureWindowKey()
    }

    private func makeFixtureWindowKey() {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(workspaceWindow.waitForExistence(timeout: 5))
        workspaceWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        app.activate()
        workspaceWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        editor.click()
        waitForKeyboardFocus(editor)
    }

    func openFindWithShortcut() throws -> XCUIElement {
        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        waitForKeyboardFocus(editor)
        let findBar = findElement("plainsong.editorFind.bar")
        wait(
            for: NSPredicate(format: "exists == false"),
            on: findBar,
            timeout: 2,
            description: "find bar to be absent before the first Command-F"
        )
        try pressCommandF()

        let queryField = findElement("plainsong.editorFind.queryField")
        XCTAssertTrue(queryField.waitForExistence(timeout: 5))
        waitForKeyboardFocus(queryField)
        return queryField
    }

    private func pressCommandF(
        immediatelyBeforeInjection: (() -> Void)? = nil
    ) throws {
        let menuItem = app.menuItems["Find…"].firstMatch
        wait(
            for: NSPredicate(format: "exists == true AND enabled == true"),
            on: menuItem,
            timeout: 5,
            description: "enabled production Find menu item"
        )

        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        waitForKeyboardFocus(editor)
        try typeCommandKey(
            "f",
            on: editor,
            immediatelyBeforeInjection: immediatelyBeforeInjection
        )
    }

    func typeCommandKey(
        _ key: String,
        on element: XCUIElement,
        immediatelyBeforeInjection: (() -> Void)? = nil
    ) throws {
        // XCUI's public textual-key API is interpreted through the selected input source.
        // Scope it to any enabled, selectable ASCII-capable source only while testmanagerd
        // synthesizes this shortcut, then restore and read back the exact prior source.
        do {
            let identifier = try shortcutInputSource.withASCIICapableInputSource {
                immediatelyBeforeInjection?()
                element.typeKey(
                    XCUIKeyboardKey(rawValue: key),
                    modifierFlags: .command
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
                    "The runner's input source changed externally during shortcut injection: "
                        + identifier
                )
            default:
                throw error
            }
        }
    }

    private func assertStableFindChromeExists(queryField: XCUIElement) {
        XCTAssertTrue(queryField.exists)
        for identifier in [
            "plainsong.editorFind.bar",
            "plainsong.editorFind.matchCase",
            "plainsong.editorFind.wholeWord",
            "plainsong.editorFind.previous",
            "plainsong.editorFind.next",
            "plainsong.editorFind.done",
        ] {
            XCTAssertTrue(
                findElement(identifier).waitForExistence(timeout: 5),
                "Missing launched-app accessibility surface \(identifier)"
            )
        }
    }

    func findElement(_ identifier: String) -> XCUIElement {
        workspaceWindow.descendants(matching: .any)[identifier]
    }

    func paste(_ value: String) throws {
        try ownedPasteboard.writeString(value)
        try typeCommandKey("v", on: workspaceWindow)
    }

    func waitForKeyboardFocus(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        wait(
            for: NSPredicate(format: "hasKeyboardFocus == true"),
            on: element,
            timeout: timeout,
            description: "keyboard focus on \(element.identifier)"
        )
    }

    private func waitForKeyboardBlur(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        wait(
            for: NSPredicate(format: "hasKeyboardFocus == false"),
            on: element,
            timeout: timeout,
            description: "keyboard focus leaving \(element.identifier)"
        )
    }

    func waitForValue(
        _ expectedValue: String,
        of element: XCUIElement,
        description: String,
        timeout: TimeInterval = 10
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(description)")
        wait(
            for: NSPredicate(format: "value == %@", expectedValue),
            on: element,
            timeout: timeout,
            description: description
        )
    }

    private func waitForValueSuffix(
        _ suffix: String,
        of element: XCUIElement,
        description: String,
        timeout: TimeInterval = 10
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(description)")
        wait(
            for: NSPredicate(format: "value ENDSWITH %@", suffix),
            on: element,
            timeout: timeout,
            description: description
        )
    }

    func wait(
        for predicate: NSPredicate,
        on element: XCUIElement,
        timeout: TimeInterval,
        description: String
    ) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Timed out waiting for \(description)"
        )
    }
}
