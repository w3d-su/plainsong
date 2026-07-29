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

    func testRuntimeDiscoveryUsesCapabilitiesAndRestoresExactCurrentSource() throws {
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        defer {
            try? EditorFindSyntheticShortcutInputSource.restoreExactInputSource(original)
        }
        let eligible = EditorFindSyntheticShortcutInputSource
            .eligibleCapabilities(
                from: EditorFindSyntheticShortcutInputSource.discoveredCapabilities()
            )
        guard !eligible.isEmpty else {
            throw XCTSkip("This runner has no enabled, selectable ASCII input source")
        }

        var didRunBody = false
        let selectedIdentifier = try EditorFindSyntheticShortcutInputSource
            .withASCIICapableInputSource {
                didRunBody = true
            }

        XCTAssertTrue(didRunBody)
        XCTAssertTrue(eligible.map(\.identifier).contains(selectedIdentifier))
        try EditorFindSyntheticShortcutInputSource.restoreExactInputSource(original)
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
