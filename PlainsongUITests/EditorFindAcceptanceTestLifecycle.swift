import AppKit
import XCTest

private struct EditorFindCleanupOutcome {
    var didRequestGracefulQuit = false
    var didRequestCleanupHandshake = false
    var didReceiveCleanupReceipt = false
    var didExitGracefully = false
    var didReachNotRunning = false
    var completionPath = "none"
}

private struct EditorFindRestorationReport {
    var inputSourceEvents: [String] = []
    var pasteboardEvents: [String] = []
}

extension EditorFindAcceptanceTests {
    func terminateApplication() {
        var restoration = EditorFindRestorationReport()
        attemptInputSourceRestoration(
            phase: "before app termination",
            report: &restoration
        )
        attemptPasteboardRestoration(
            phase: "before app termination",
            report: &restoration
        )

        let outcome = completeAppCleanupAndQuit()
        let selectedSourceSummary = selectedASCIISourceIdentifiers
            .sorted()
            .joined(separator: ", ")
        app = nil
        workspaceWindow = nil

        if shortcutInputSource.hasPendingRestoration {
            attemptInputSourceRestoration(
                phase: "after app termination retry",
                report: &restoration
            )
        }
        if ownedPasteboard.hasPendingRestoration {
            attemptPasteboardRestoration(
                phase: "after app termination retry",
                report: &restoration
            )
        }

        if outcome.didReachNotRunning {
            let cleanupChannel = cleanupPasteboard()
            cleanupChannel.clearContents()
            cleanupChannel.releaseGlobally()
        }
        reportCleanup(
            outcome,
            selectedSourceSummary: selectedSourceSummary,
            restoration: restoration
        )
    }

    private func attemptInputSourceRestoration(
        phase: String,
        report: inout EditorFindRestorationReport
    ) {
        do {
            let outcome = try shortcutInputSource
                .restorePendingSelectionIfOwned()
            report.inputSourceEvents.append("\(phase): \(outcome)")
        } catch {
            report.inputSourceEvents.append("\(phase) failed: \(error)")
        }
    }

    private func attemptPasteboardRestoration(
        phase: String,
        report: inout EditorFindRestorationReport
    ) {
        do {
            let outcome = try ownedPasteboard.restoreIfStillOwned()
            report.pasteboardEvents.append("\(phase): \(outcome)")
        } catch {
            report.pasteboardEvents.append("\(phase) failed: \(error)")
        }
    }

    private func completeAppCleanupAndQuit() -> EditorFindCleanupOutcome {
        let expectedReceipt = "removed:\(fixtureIdentifier):\(cleanupToken)"
        var outcome = EditorFindCleanupOutcome(
            didExitGracefully: app.state == .notRunning,
            didReachNotRunning: app.state == .notRunning
        )
        if !outcome.didExitGracefully {
            outcome.didRequestCleanupHandshake = requestAppSideCleanupAndQuit()
            if outcome.didRequestCleanupHandshake {
                outcome.didReceiveCleanupReceipt = waitForCleanupReceipt(expectedReceipt)
                outcome.didExitGracefully = app.wait(for: .notRunning, timeout: 10)
                outcome.didReachNotRunning = outcome.didExitGracefully
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
                outcome.didReachNotRunning = outcome.didExitGracefully
                if outcome.didReceiveCleanupReceipt, outcome.didExitGracefully {
                    outcome.completionPath = "Quit menu"
                }
            }
        }
        if !outcome.didExitGracefully {
            app.terminate()
            outcome.didReachNotRunning = app.wait(for: .notRunning, timeout: 5)
        }
        return outcome
    }

    private func reportCleanup(
        _ outcome: EditorFindCleanupOutcome,
        selectedSourceSummary: String,
        restoration: EditorFindRestorationReport
    ) {
        print(
            "F9 cleanup receipt \(outcome.didReceiveCleanupReceipt ? "verified" : "missing"): "
                + fixtureIdentifier
        )
        print("F9 cleanup completion: \(outcome.completionPath)")
        print("F9 synthetic ASCII input source(s): \(selectedSourceSummary)")
        print(
            "F9 input-source restoration: "
                + restoration.inputSourceEvents.joined(separator: "; ")
        )
        print(
            "F9 pasteboard restoration: "
                + restoration.pasteboardEvents.joined(separator: "; ")
        )

        XCTAssertFalse(
            shortcutInputSource.hasPendingRestoration,
            "Input-source restoration still failed after the post-termination retry"
        )
        XCTAssertFalse(
            ownedPasteboard.hasPendingRestoration,
            "General-pasteboard restoration still failed after the post-termination retry"
        )
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
        let pasteboard = cleanupPasteboard()
        pasteboard.clearContents()
        let request = "quit:\(fixtureIdentifier):\(cleanupToken)"
        return pasteboard.setString(
            request,
            forType: Self.cleanupRequestType
        ) && pasteboard.string(forType: Self.cleanupRequestType) == request
    }

    private func waitForCleanupReceipt(
        _ expectedReceipt: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        let predicate = NSPredicate { _, _ in
            self.cleanupPasteboard().string(
                forType: Self.cleanupReceiptType
            ) == expectedReceipt
        }
        return predicateCompletes(
            predicate,
            on: NSObject(),
            timeout: timeout
        )
    }

    private func cleanupPasteboard() -> NSPasteboard {
        NSPasteboard(
            name: .init(
                "app.plainsong.editor.debug.editor-find-cleanup.\(cleanupToken)"
            )
        )
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
