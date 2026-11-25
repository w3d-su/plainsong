import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentOpenCleanupTests: XCTestCase {
    func testUndecodableOpenClosesTheProvider() async throws {
        let harness = DocumentIOHarness()
        harness.ports.openedData = Data([0xFF, 0xFE, 0x00])
        let location = harness.location(relativePath: "Note.md", generation: 1)
        do {
            _ = try await harness.store.open(location, lease: harness.directoryLease(generation: 1))
            XCTFail("non-UTF-8 open must fail")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .access(.unsupportedType))
        }
        let port = try XCTUnwrap(harness.ports.port(fileURL: location.fileURL))
        XCTAssertEqual(port.openCalls, 1)
        XCTAssertEqual(port.closeCalls, 1)
        XCTAssertNil(harness.store.byResource[IOSDocumentResourceKey(location: location)])
    }

    func testCancelledOpenClosesTheProvider() async throws {
        let harness = DocumentIOHarness()
        harness.ports.blockOpen = true
        let location = harness.location(relativePath: "Note.md", generation: 1)
        let lease = harness.directoryLease(generation: 1)
        let opening = Task { try await harness.store.open(location, lease: lease) }
        await waitUntil { harness.ports.port(fileURL: location.fileURL)?.parked == 1 }
        let port = try XCTUnwrap(harness.ports.port(fileURL: location.fileURL))
        opening.cancel()
        port.releaseOne()
        do {
            _ = try await opening.value
            XCTFail("cancelled open must fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(port.closeCalls, 1)
    }

    func testCoalescedOpenReleasesItsLeaseWhenTheDocumentCloses() async throws {
        let harness = DocumentIOHarness()
        let location = harness.location(relativePath: "Note.md", generation: 1)
        let first = harness.directoryLease(generation: 1)
        let second = harness.directoryLease(generation: 1)
        let handle = try await harness.store.open(location, lease: first)
        let joined = try await harness.store.open(location, lease: second)
        XCTAssertEqual(joined.identity, handle.identity)
        XCTAssertEqual(harness.ports.port(fileURL: location.fileURL)?.openCalls, 1)
        XCTAssertFalse(second.isReleased)
        _ = try await harness.store.close(handle.identity)
        XCTAssertTrue(first.isReleased)
        XCTAssertTrue(second.isReleased)
    }
}
