import Carbon
import XCTest

@MainActor
final class EditorFindInputSourceTests: XCTestCase {
    func testEligibilityDoesNotAllowlistKeyboardLayoutIdentifiers() {
        let identifiers = [
            "com.apple.keylayout.British",
            "com.apple.keylayout.Dvorak",
            "com.apple.keylayout.Colemak",
        ]
        let candidates = identifiers.map {
            capabilities(identifier: $0)
        }

        XCTAssertEqual(
            EditorFindSyntheticShortcutInputSource.orderedEligibleCandidates(
                from: candidates,
                capabilities: { $0 }
            ).map(\.capabilities.identifier),
            identifiers
        )
    }

    func testEligibilityRejectsEachMissingRequiredCapability() {
        let candidates = [
            capabilities(identifier: "not-keyboard", isKeyboardInputSource: false),
            capabilities(identifier: "disabled", isEnabled: false),
            capabilities(identifier: "not-selectable", isSelectCapable: false),
            capabilities(identifier: "not-ascii", isASCIICapable: false),
        ]

        XCTAssertTrue(
            EditorFindSyntheticShortcutInputSource.eligibleCapabilities(
                from: candidates
            ).isEmpty
        )
    }

    func testEligibilityPreservesSystemCandidatePreferenceOrder() {
        let currentBritish = capabilities(identifier: "com.apple.keylayout.British")
        let recentDvorak = capabilities(identifier: "com.apple.keylayout.Dvorak")
        let discoveredColemak = capabilities(identifier: "com.apple.keylayout.Colemak")

        XCTAssertEqual(
            EditorFindSyntheticShortcutInputSource.orderedEligibleCandidates(
                from: [currentBritish, recentDvorak, discoveredColemak],
                capabilities: { $0 }
            ).map(\.capabilities),
            [currentBritish, recentDvorak, discoveredColemak]
        )
    }

    func testRestorationDecisionRestoresOnlyTheSessionSelectedSource() {
        XCTAssertEqual(
            EditorFindSyntheticShortcutInputSource.restorationDecision(
                originalIdentifier: "original",
                selectedIdentifier: "selected",
                currentIdentifier: nil
            ),
            .readbackUnavailable
        )
        XCTAssertEqual(
            EditorFindSyntheticShortcutInputSource.restorationDecision(
                originalIdentifier: "original",
                selectedIdentifier: "selected",
                currentIdentifier: "selected"
            ),
            .restoreOriginal
        )
        XCTAssertEqual(
            EditorFindSyntheticShortcutInputSource.restorationDecision(
                originalIdentifier: "original",
                selectedIdentifier: "selected",
                currentIdentifier: "original"
            ),
            .alreadyOriginal
        )
        XCTAssertEqual(
            EditorFindSyntheticShortcutInputSource.restorationDecision(
                originalIdentifier: "original",
                selectedIdentifier: "selected",
                currentIdentifier: "external"
            ),
            .preserveExternalChange
        )
    }

    func testRuntimeDiscoveryUsesCapabilitiesAndRestoresExactCurrentSource() throws {
        let originalIdentifier = try XCTUnwrap(
            EditorFindSyntheticShortcutInputSource
                .currentInputSourceIdentifier()
        )
        let inputSource = EditorFindSyntheticShortcutInputSource()
        defer {
            _ = try? inputSource.restorePendingSelectionIfOwned()
        }
        let eligible = EditorFindSyntheticShortcutInputSource
            .eligibleCapabilities(
                from: EditorFindSyntheticShortcutInputSource.discoveredCapabilities()
            )
        guard !eligible.isEmpty else {
            throw XCTSkip("This runner has no enabled, selectable ASCII input source")
        }

        var didRunBody = false
        let selectedIdentifier = try inputSource.withASCIICapableInputSource {
            didRunBody = true
        }

        XCTAssertTrue(didRunBody)
        XCTAssertTrue(eligible.map(\.identifier).contains(selectedIdentifier))
        XCTAssertFalse(inputSource.hasPendingRestoration)
        XCTAssertEqual(
            EditorFindSyntheticShortcutInputSource
                .currentInputSourceIdentifier(),
            originalIdentifier
        )
    }

    func testUnreadableCurrentSourceRetainsLeaseForRetry() throws {
        var readbacks: [String?] = [
            nil,
            "selected",
            "selected",
            "original",
        ]
        let inputSource = EditorFindSyntheticShortcutInputSource(
            currentIdentifierReader: {
                readbacks.removeFirst()
            },
            selector: { _ in noErr }
        )
        inputSource.installPendingSelectionLeaseForTesting(
            originalIdentifier: "original",
            selectedIdentifier: "selected"
        )

        XCTAssertThrowsError(
            try inputSource.restorePendingSelectionIfOwned()
        ) { error in
            guard case EditorFindSyntheticShortcutInputSource.InputSourceError
                .currentInputSourceIdentifierUnavailable = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(inputSource.hasPendingRestoration)

        XCTAssertEqual(
            try inputSource.restorePendingSelectionIfOwned(),
            .restored
        )
        XCTAssertFalse(inputSource.hasPendingRestoration)
        XCTAssertTrue(readbacks.isEmpty)
    }

    func testFailedRestoreRetainsLeaseUntilVerifiedRetry() throws {
        var readbacks: [String?] = [
            "selected",
            "selected",
            "selected",
            "selected",
            "original",
        ]
        var selectionStatuses: [OSStatus] = [OSStatus(paramErr), noErr]
        let inputSource = EditorFindSyntheticShortcutInputSource(
            currentIdentifierReader: {
                readbacks.removeFirst()
            },
            selector: { _ in
                selectionStatuses.removeFirst()
            }
        )
        inputSource.installPendingSelectionLeaseForTesting(
            originalIdentifier: "original",
            selectedIdentifier: "selected"
        )

        XCTAssertThrowsError(
            try inputSource.restorePendingSelectionIfOwned()
        ) { error in
            guard case let EditorFindSyntheticShortcutInputSource.InputSourceError
                .couldNotRestoreInputSource(identifier, status) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identifier, "original")
            XCTAssertEqual(status, OSStatus(paramErr))
        }
        XCTAssertTrue(inputSource.hasPendingRestoration)

        XCTAssertEqual(
            try inputSource.restorePendingSelectionIfOwned(),
            .restored
        )
        XCTAssertFalse(inputSource.hasPendingRestoration)
        XCTAssertTrue(readbacks.isEmpty)
        XCTAssertTrue(selectionStatuses.isEmpty)
    }

    func testExternalChangeAtRestoreBoundaryIsPreservedWithoutSelection() throws {
        var readbacks: [String?] = ["selected", "external"]
        var selectionCount = 0
        let inputSource = EditorFindSyntheticShortcutInputSource(
            currentIdentifierReader: {
                readbacks.removeFirst()
            },
            selector: { _ in
                selectionCount += 1
                return noErr
            }
        )
        inputSource.installPendingSelectionLeaseForTesting(
            originalIdentifier: "original",
            selectedIdentifier: "selected"
        )

        XCTAssertEqual(
            try inputSource.restorePendingSelectionIfOwned(),
            .externalChangePreserved("external")
        )
        XCTAssertFalse(inputSource.hasPendingRestoration)
        XCTAssertEqual(selectionCount, 0)
        XCTAssertTrue(readbacks.isEmpty)
    }

    func testSelectedCandidateReturningToOriginalDuringShortcutIsNotAccepted() {
        XCTAssertThrowsError(
            try EditorFindSyntheticShortcutInputSource
                .requireStableSelectedCandidateRestoration(
                    .alreadyOriginal,
                    originalIdentifier: "original",
                    selectedIdentifier: "selected"
                )
        ) { error in
            guard case let EditorFindSyntheticShortcutInputSource.InputSourceError
                .currentSourceChangedDuringShortcut(identifier) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identifier, "original")
        }
    }

    private func capabilities(
        identifier: String,
        isKeyboardInputSource: Bool = true,
        isEnabled: Bool = true,
        isSelectCapable: Bool = true,
        isASCIICapable: Bool = true
    ) -> EditorFindInputSourceCapabilities {
        EditorFindInputSourceCapabilities(
            identifier: identifier,
            isKeyboardInputSource: isKeyboardInputSource,
            isEnabled: isEnabled,
            isSelectCapable: isSelectCapable,
            isASCIICapable: isASCIICapable
        )
    }
}
