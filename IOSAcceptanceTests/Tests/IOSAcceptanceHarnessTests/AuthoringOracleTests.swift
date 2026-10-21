import Foundation
@testable import IOSAcceptanceHarness
import MarkdownCore
import XCTest

/// The probe's `undoRegistrations` value is a counter in this process. It does not
/// record an `UndoManager` action.
final class AuthoringOracleTests: XCTestCase {
    func testSecondHitReplacesOnlyThatMatch() {
        let source = "see 👩‍💻 and 👩‍💻"
        let second = NSRange(location: 14, length: 5)
        XCTAssertEqual((source as NSString).substring(with: second), "👩‍💻")
        var probe = EditorProbe(source: source, selection: second)
        let authority = authority(source: source, selection: second)
        let replacement = "工程師"
        XCTAssertTrue(
            AuthoringAcceptance.singleReplace(
                probe: &probe,
                captured: authority,
                live: authority,
                pattern: "👩‍💻",
                replacement: replacement
            )
        )
        XCTAssertEqual(probe.source, "see 👩‍💻 and 工程師")
        XCTAssertEqual(
            probe.selection,
            NSRange(location: second.location + (replacement as NSString).length, length: 0)
        )
        XCTAssertEqual(probe.undoRegistrations, 1)
    }

    func testUnacceptedAndStaleSelectionsDoNotEdit() {
        let source = "see 👩‍💻 and 👩‍💻"
        let prefix = NSRange(location: 0, length: 4)
        var probe = EditorProbe(source: source, selection: prefix)
        let prefixAuthority = authority(source: source, selection: prefix)
        XCTAssertFalse(
            AuthoringAcceptance.singleReplace(
                probe: &probe,
                captured: prefixAuthority,
                live: prefixAuthority,
                pattern: "👩‍💻",
                replacement: "工程師"
            )
        )
        XCTAssertEqual(probe, EditorProbe(source: source, selection: prefix))

        let second = NSRange(location: 14, length: 5)
        var moved = EditorProbe(source: source, selection: second)
        let captured = authority(source: source, selection: second)
        var live = captured
        live.selection = NSRange(location: 4, length: 5)
        live.selectionGeneration += 1
        let beforeMove = moved
        XCTAssertFalse(
            AuthoringAcceptance.singleReplace(
                probe: &moved,
                captured: captured,
                live: live,
                pattern: "👩‍💻",
                replacement: "工程師"
            )
        )
        XCTAssertEqual(moved, beforeMove)

        let staleSource = "see cat and 👩‍💻"
        let staleSelection = NSRange(location: 14, length: 5)
        XCTAssertGreaterThan(
            staleSelection.location + staleSelection.length,
            (staleSource as NSString).length
        )
        var stale = EditorProbe(source: staleSource, selection: staleSelection)
        let staleAuthority = authority(source: staleSource, selection: staleSelection)
        XCTAssertFalse(
            AuthoringAcceptance.singleReplace(
                probe: &stale,
                captured: staleAuthority,
                live: staleAuthority,
                pattern: "👩‍💻",
                replacement: "工程師"
            )
        )
        XCTAssertEqual(stale.source, staleSource)
        XCTAssertEqual(stale.selection, staleSelection)
        XCTAssertEqual(stale.undoRegistrations, 0)
    }

    private func authority(source: String, selection: NSRange) -> AuthoringAuthority {
        AuthoringAuthority(
            bindingID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            documentID: IOSDocumentIdentity(
                rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            ),
            version: 3,
            selectionGeneration: 4,
            source: source,
            selection: selection
        )
    }
}
