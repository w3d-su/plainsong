import AppKit
import XCTest

@MainActor
final class WorkspaceSearchAcceptanceTests: XCTestCase, @unchecked Sendable {
    private var app: XCUIApplication!
    private var workspaceWindow: XCUIElement!
    private var savedPasteboardItems: [[NSPasteboard.PasteboardType: Data]] = []

    private func launchApplication() {
        continueAfterFailure = false
        savedPasteboardItems = snapshotGeneralPasteboard()
        app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["PLAINSONG_DEBUG_WORKSPACE_SEARCH_FIXTURE"] =
            "ws4a-\(UUID().uuidString)"
        app.launch()
        app.activate()

        addTeardownBlock { [weak self] in
            await self?.terminateApplication()
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
        app.terminate()
        app = nil
        workspaceWindow = nil
        restoreGeneralPasteboard()
    }

    func testShortcutKeyboardActivationAndEscapeTransitions() {
        launchApplication()
        let queryField = openSearchWithShortcut()
        enterCJKQuery(in: queryField)

        let first = resultRow(relativePath: "a-overview.md")
        let target = resultRow(relativePath: "posts/b-target.mdx")
        let last = resultRow(relativePath: "z-last.md")
        assertGroupedResultsExist()

        queryField.typeKey(.downArrow, modifierFlags: [])
        waitForSelected(first)

        app.typeKey(.upArrow, modifierFlags: [])
        waitForSelected(first)

        app.typeKey(.downArrow, modifierFlags: [])
        waitForSelected(target)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForSelected(last)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForSelected(last)
        app.typeKey(.upArrow, modifierFlags: [])
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
            "Workspace search focus results",
            of: workspaceWindow.descendants(matching: .any)[
                "plainsong.debug.workspaceSearch.focusSurface"
            ],
            description: "results focus restored after activation"
        )

        // Deliberately do not wait for the first Escape's forced query-focus confirmation
        // loop. The second Escape must supersede that in-flight intent and leave the editor
        // focused rather than allowing Search to reclaim first responder.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        waitForKeyboardFocus(editor)
        assertQueryAndResultsRemain(queryField: queryField, target: target)
    }

    func testClickThenArrowKeysUseSearchSelection() {
        launchApplication()
        let queryField = openSearchWithShortcut()
        enterCJKQuery(in: queryField)

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
        waitForLabel(
            "Workspace search reducer moveUp",
            of: reducerProbe,
            description: "custom results reducer receiving Up"
        )
        waitForSelected(first)
        app.typeKey(.upArrow, modifierFlags: [])
        waitForSelected(first)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForLabel(
            "Workspace search reducer moveDown",
            of: reducerProbe,
            description: "custom results reducer receiving Down"
        )
        waitForSelected(target)
    }

    private func openSearchWithShortcut() -> XCUIElement {
        makeFixtureWindowKey()
        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeKey("f", modifierFlags: [.command, .shift])
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
        app.typeKey("x", modifierFlags: [])
        waitForValue("x", of: queryField, description: "shortcut-focused query field")
        return queryField
    }

    private func enterCJKQuery(in queryField: XCUIElement) {
        queryField.click()
        queryField.typeKey("a", modifierFlags: .command)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("搜尋", forType: .string))
        app.typeKey("v", modifierFlags: .command)
        waitForValue("搜尋", of: queryField, description: "CJK query")
    }

    private func snapshotGeneralPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        NSPasteboard.general.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
    }

    private func restoreGeneralPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = savedPasteboardItems.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
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
