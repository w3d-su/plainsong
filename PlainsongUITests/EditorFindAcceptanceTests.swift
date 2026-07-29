import AppKit
import Carbon
import XCTest

@MainActor
final class EditorFindAcceptanceTests: XCTestCase, @unchecked Sendable {
    private var app: XCUIApplication!
    private var workspaceWindow: XCUIElement!
    private var savedPasteboardItems: [[NSPasteboard.PasteboardType: Data]] = []
    private var savedKeyboardInputSource: TISInputSource?

    func testRepeatedCommandFRefocusesSelectsAllAndLeavesBarOpen() {
        launchApplication()
        let queryField = openFindWithShortcut()
        assertStableFindChromeExists(queryField: queryField)
        paste("needle")
        waitForValue("needle", of: queryField, description: "initial find query")
        XCTAssertTrue(
            findElement("plainsong.editorFind.matchCounter").waitForExistence(timeout: 10),
            "The launched app did not expose the active-query match counter"
        )

        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        editor.click()
        waitForKeyboardFocus(editor)
        waitForKeyboardBlur(queryField)

        pressCommandF()
        waitForKeyboardFocus(queryField)
        paste("q")

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

    func testExactAndTruncatedCountersAreObservablyDistinct() {
        launchApplication()
        let queryField = openFindWithShortcut()
        let counter = findElement("plainsong.editorFind.matchCounter")
        let truncated = findElement("plainsong.editorFind.truncated")

        paste("needle")
        waitForValue("1 / 3", of: counter, description: "exact match counter")
        XCTAssertFalse(
            truncated.exists,
            "An exact match total must not expose the truncated-state indicator"
        )

        typeCommandKey("a", on: queryField)
        paste("x")
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

    private func launchApplication() {
        continueAfterFailure = false
        savedPasteboardItems = snapshotGeneralPasteboard()
        savedKeyboardInputSource =
            TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["PLAINSONG_DEBUG_EDITOR_FIND_FIXTURE"] =
            "f9-\(UUID().uuidString)"

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
        makeFixtureWindowKey()
    }

    private func terminateApplication() {
        let keyboardRestoreStatus = savedKeyboardInputSource.map(TISSelectInputSource)
        savedKeyboardInputSource = nil
        app.terminate()
        app = nil
        workspaceWindow = nil
        restoreGeneralPasteboard()
        if let keyboardRestoreStatus {
            XCTAssertEqual(
                keyboardRestoreStatus,
                noErr,
                "Could not restore the launch-time keyboard input source during teardown"
            )
        }
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

    private func openFindWithShortcut() -> XCUIElement {
        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        waitForKeyboardFocus(editor)
        pressCommandF()

        let queryField = findElement("plainsong.editorFind.queryField")
        XCTAssertTrue(queryField.waitForExistence(timeout: 5))
        waitForKeyboardFocus(queryField)
        return queryField
    }

    private func pressCommandF() {
        let menuItem = app.menuItems["Find…"].firstMatch
        wait(
            for: NSPredicate(format: "exists == true AND enabled == true"),
            on: menuItem,
            timeout: 5,
            description: "enabled production Find menu item"
        )

        let editor = workspaceWindow.textViews["plainsong.editor.textView"]
        waitForKeyboardFocus(editor)
        typeCommandKey("f", on: editor)
    }

    private func typeCommandKey(_ key: String, on element: XCUIElement) {
        // XCUI's public textual-key API is interpreted through the selected input source.
        // Scope it to a Latin keyboard only while testmanagerd synthesizes this shortcut,
        // then restore the user's source immediately. This remains synthetic UI-acceptance
        // evidence; it is deliberately not described as physical-keyboard evidence.
        withLatinInputSource {
            element.typeKey(XCUIKeyboardKey(rawValue: key), modifierFlags: .command)
        }
    }

    private func withLatinInputSource(_ body: () -> Void) {
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let identifiers = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        var selectedLatinSource: TISInputSource?
        for identifier in identifiers {
            for candidate in inputSources(identifier: identifier)
                where TISSelectInputSource(candidate) == noErr
            {
                selectedLatinSource = candidate
                break
            }
            if selectedLatinSource != nil {
                break
            }
        }
        guard selectedLatinSource != nil else {
            return XCTFail("No enabled, select-capable Latin keyboard input source is available")
        }
        defer {
            XCTAssertEqual(
                TISSelectInputSource(original),
                noErr,
                "Could not restore the original keyboard input source"
            )
        }
        body()
    }

    private func inputSources(identifier: String) -> [TISInputSource] {
        let properties = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        let sources = TISCreateInputSourceList(properties, false).takeRetainedValue() as NSArray
        return sources.compactMap { source in
            // swiftlint:disable:next force_cast
            let inputSource = (source as! TISInputSource)
            guard
                inputSourceHasTrueProperty(
                    inputSource,
                    key: kTISPropertyInputSourceIsEnabled
                ),
                inputSourceHasTrueProperty(
                    inputSource,
                    key: kTISPropertyInputSourceIsSelectCapable
                )
            else {
                return nil
            }
            return inputSource
        }
    }

    private func inputSourceHasTrueProperty(
        _ inputSource: TISInputSource,
        key: CFString
    ) -> Bool {
        guard let rawValue = TISGetInputSourceProperty(inputSource, key) else {
            return false
        }
        return CFBooleanGetValue(
            Unmanaged<CFBoolean>.fromOpaque(rawValue).takeUnretainedValue()
        )
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

    private func findElement(_ identifier: String) -> XCUIElement {
        workspaceWindow.descendants(matching: .any)[identifier]
    }

    private func paste(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(value, forType: .string))
        typeCommandKey("v", on: workspaceWindow)
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

    private func waitForKeyboardFocus(
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

    private func waitForValue(
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

    private func wait(
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
