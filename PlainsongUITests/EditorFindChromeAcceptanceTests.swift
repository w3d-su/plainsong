import XCTest

extension EditorFindAcceptanceTests {
    func testFindChromeRolesStatesAndActionsAreObservable() throws {
        launchApplication()
        let queryField = try openFindWithShortcut()
        let findBar = findElement("plainsong.editorFind.bar")
        let matchCase = findElement("plainsong.editorFind.matchCase")
        let wholeWord = findElement("plainsong.editorFind.wholeWord")
        let previous = findElement("plainsong.editorFind.previous")
        let next = findElement("plainsong.editorFind.next")
        let done = findElement("plainsong.editorFind.done")
        let counter = findElement("plainsong.editorFind.matchCounter")

        assertChromeRoles(
            queryField: queryField,
            matchCase: matchCase,
            wholeWord: wholeWord,
            previous: previous,
            next: next,
            done: done
        )
        assertInitialChromeStates(
            matchCase: matchCase,
            wholeWord: wholeWord,
            previous: previous,
            next: next,
            done: done
        )
        try assertCaseAndWholeWordActions(
            queryField: queryField,
            counter: counter,
            matchCase: matchCase,
            wholeWord: wholeWord
        )
        try assertNavigationAndDoneActions(
            queryField: queryField,
            counter: counter,
            previous: previous,
            next: next,
            done: done,
            findBar: findBar
        )
    }
}

private extension EditorFindAcceptanceTests {
    func assertChromeRoles(
        queryField: XCUIElement,
        matchCase: XCUIElement,
        wholeWord: XCUIElement,
        previous: XCUIElement,
        next: XCUIElement,
        done: XCUIElement
    ) {
        assertRole(.textField, of: queryField, description: "query field")
        assertRole(.checkBox, of: matchCase, description: "Match case toggle")
        assertRole(.checkBox, of: wholeWord, description: "Whole word toggle")
        for (button, description) in [
            (previous, "Find previous"),
            (next, "Find next"),
            (done, "Done"),
        ] {
            assertRole(.button, of: button, description: description)
        }
    }

    func assertInitialChromeStates(
        matchCase: XCUIElement,
        wholeWord: XCUIElement,
        previous: XCUIElement,
        next: XCUIElement,
        done: XCUIElement
    ) {
        waitForEnabled(true, of: matchCase, description: "Match case enabled")
        waitForEnabled(true, of: wholeWord, description: "Whole word enabled")
        waitForEnabled(true, of: done, description: "Done enabled")
        waitForEnabled(false, of: previous, description: "Find previous disabled")
        waitForEnabled(false, of: next, description: "Find next disabled")
        waitForToggleValue(false, of: matchCase, description: "Match case off state")
        waitForToggleValue(false, of: wholeWord, description: "Whole word off state")
    }

    func assertCaseAndWholeWordActions(
        queryField: XCUIElement,
        counter: XCUIElement,
        matchCase: XCUIElement,
        wholeWord: XCUIElement
    ) throws {
        try replaceQuery(with: "caseprobe", in: queryField)
        waitForValue("1 / 2", of: counter, description: "case-insensitive count")
        matchCase.click()
        waitForToggleValue(true, of: matchCase, description: "Match case on state")
        waitForValue("1 / 1", of: counter, description: "case-sensitive count")
        matchCase.click()
        waitForToggleValue(false, of: matchCase, description: "Match case restored off")
        waitForValue("1 / 2", of: counter, description: "restored case-insensitive count")

        try replaceQuery(with: "wordprobe", in: queryField)
        waitForValue("1 / 3", of: counter, description: "substring count")
        wholeWord.click()
        waitForToggleValue(true, of: wholeWord, description: "Whole word on state")
        waitForValue("1 / 1", of: counter, description: "whole-word count")
        wholeWord.click()
        waitForToggleValue(false, of: wholeWord, description: "Whole word restored off")
        waitForValue("1 / 3", of: counter, description: "restored substring count")
    }

    func assertNavigationAndDoneActions(
        queryField: XCUIElement,
        counter: XCUIElement,
        previous: XCUIElement,
        next: XCUIElement,
        done: XCUIElement,
        findBar: XCUIElement
    ) throws {
        try replaceQuery(with: "needle", in: queryField)
        waitForValue("1 / 3", of: counter, description: "initial navigation count")
        waitForEnabled(true, of: previous, description: "Find previous enabled")
        waitForEnabled(true, of: next, description: "Find next enabled")
        next.click()
        waitForValue("2 / 3", of: counter, description: "next-match outcome")
        previous.click()
        waitForValue("1 / 3", of: counter, description: "previous-match outcome")

        done.click()
        wait(
            for: NSPredicate(format: "exists == false"),
            on: findBar,
            timeout: 5,
            description: "Done closing the find bar"
        )
        waitForKeyboardFocus(
            workspaceWindow.textViews["plainsong.editor.textView"]
        )
    }

    func assertRole(
        _ expectedRole: XCUIElement.ElementType,
        of element: XCUIElement,
        description: String
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(description)")
        XCTAssertEqual(
            element.elementType,
            expectedRole,
            "\(description) exposed the wrong accessibility role"
        )
    }

    func replaceQuery(
        with value: String,
        in queryField: XCUIElement
    ) throws {
        queryField.click()
        waitForKeyboardFocus(queryField)
        try typeCommandKey("a", on: queryField)
        try paste(value)
        waitForValue(value, of: queryField, description: "query \(value)")
    }

    func waitForEnabled(
        _ expectedValue: Bool,
        of element: XCUIElement,
        description: String,
        timeout: TimeInterval = 10
    ) {
        wait(
            for: NSPredicate(format: "enabled == %@", NSNumber(value: expectedValue)),
            on: element,
            timeout: timeout,
            description: description
        )
    }

    func waitForToggleValue(
        _ expectedValue: Bool,
        of element: XCUIElement,
        description: String,
        timeout: TimeInterval = 10
    ) {
        wait(
            for: NSPredicate(format: "value == %@", NSNumber(value: expectedValue)),
            on: element,
            timeout: timeout,
            description: description
        )
    }
}
