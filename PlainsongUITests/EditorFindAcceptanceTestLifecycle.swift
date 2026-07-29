import AppKit
import XCTest

private struct EditorFindCleanupOutcome {
    var didRequestGracefulQuit = false
    var didRequestCleanupHandshake = false
    var didReceiveCleanupReceipt = false
    var didExitGracefully = false
    var completionPath = "none"
}

extension EditorFindAcceptanceTests {
    func terminateApplication() {
        let keyboardRestoreFailure = restoreLaunchInputSource()
        let outcome = completeAppCleanupAndQuit()
        let selectedSourceSummary = selectedASCIISourceIdentifiers
            .sorted()
            .joined(separator: ", ")
        app = nil
        workspaceWindow = nil
        restoreGeneralPasteboard()
        reportCleanup(
            outcome,
            selectedSourceSummary: selectedSourceSummary,
            keyboardRestoreFailure: keyboardRestoreFailure
        )
    }

    private func restoreLaunchInputSource() -> String? {
        defer { savedKeyboardInputSource = nil }
        guard let savedKeyboardInputSource else {
            return nil
        }
        do {
            try EditorFindSyntheticShortcutInputSource.restoreExactInputSource(
                savedKeyboardInputSource
            )
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private func completeAppCleanupAndQuit() -> EditorFindCleanupOutcome {
        let expectedReceipt = "removed:\(fixtureIdentifier):\(cleanupToken)"
        var outcome = EditorFindCleanupOutcome(
            didExitGracefully: app.state == .notRunning
        )
        if !outcome.didExitGracefully {
            outcome.didRequestCleanupHandshake = requestAppSideCleanupAndQuit()
            if outcome.didRequestCleanupHandshake {
                outcome.didReceiveCleanupReceipt = waitForCleanupReceipt(expectedReceipt)
                outcome.didExitGracefully = app.wait(for: .notRunning, timeout: 10)
                if outcome.didReceiveCleanupReceipt, outcome.didExitGracefully {
                    outcome.completionPath = "app-side handshake"
                }
            }
        }
        if !outcome.didExitGracefully {
            outcome.didRequestGracefulQuit = requestGracefulQuit()
            if outcome.didRequestGracefulQuit {
                outcome.didReceiveCleanupReceipt = waitForCleanupReceipt(expectedReceipt)
                outcome.didExitGracefully = app.wait(for: .notRunning, timeout: 10)
                if outcome.didReceiveCleanupReceipt, outcome.didExitGracefully {
                    outcome.completionPath = "Quit menu"
                }
            }
        }
        if !outcome.didExitGracefully {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
        }
        return outcome
    }

    private func reportCleanup(
        _ outcome: EditorFindCleanupOutcome,
        selectedSourceSummary: String,
        keyboardRestoreFailure: String?
    ) {
        print(
            "F9 cleanup receipt \(outcome.didReceiveCleanupReceipt ? "verified" : "missing"): "
                + fixtureIdentifier
        )
        print("F9 cleanup completion: \(outcome.completionPath)")
        print("F9 synthetic ASCII input source(s): \(selectedSourceSummary)")

        if let keyboardRestoreFailure {
            XCTFail(
                "Could not restore and read back the launch-time input source: "
                    + keyboardRestoreFailure
            )
        }
        XCTAssertTrue(
            outcome.didRequestGracefulQuit || outcome.didRequestCleanupHandshake,
            "Could not request the app's normal Quit or cleanup handshake path"
        )
        XCTAssertTrue(
            outcome.didReceiveCleanupReceipt,
            "The app did not verify removal of this run's exact fixture"
        )
        XCTAssertTrue(
            outcome.didExitGracefully,
            "The app did not exit through its graceful termination path"
        )
    }

    func snapshotGeneralPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        NSPasteboard.general.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
    }

    private func requestGracefulQuit() -> Bool {
        guard app.state == .runningForeground else {
            return false
        }
        let quitItem = app.menuItems["Quit Plainsong"].firstMatch
        guard predicateCompletes(
            NSPredicate(format: "exists == true AND enabled == true"),
            on: quitItem,
            timeout: 5
        ) else {
            return false
        }
        quitItem.click()
        return true
    }

    private func requestAppSideCleanupAndQuit() -> Bool {
        guard app.state != .notRunning else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(
            "quit:\(fixtureIdentifier):\(cleanupToken)",
            forType: Self.cleanupRequestType
        )
    }

    private func waitForCleanupReceipt(
        _ expectedReceipt: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        let predicate = NSPredicate { _, _ in
            NSPasteboard.general.string(forType: Self.cleanupReceiptType)
                == expectedReceipt
        }
        return predicateCompletes(
            predicate,
            on: NSObject(),
            timeout: timeout
        )
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

    private func predicateCompletes(
        _ predicate: NSPredicate,
        on object: Any,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: object
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
