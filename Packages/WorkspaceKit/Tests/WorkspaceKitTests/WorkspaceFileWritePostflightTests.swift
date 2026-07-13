import Foundation
@testable import WorkspaceKit
import XCTest

extension WorkspaceAnchoredFileSystemTests {
    func testExistingWritePostflightRootReplacementCannotReportDurable() throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let originalIdentity = try XCTUnwrap(fixture.originalIdentity)
        let movedRoot = fixture.parent.appendingPathComponent("moved-existing-postflight", isDirectory: true)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.root, to: movedRoot)
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            try "canonical replacement".write(
                to: fixture.destination,
                atomically: true,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .postflight { mutation.run() }
        })

        let outcome = write(
            to: fixture,
            expecting: .existing(originalIdentity),
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .namespaceChanged))
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        XCTAssertEqual(result.recoveryArtifact, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "canonical replacement")
        let movedDestination = movedRoot.appendingPathComponent("post.md")
        XCTAssertEqual(try writeText(at: movedDestination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: movedDestination), preparedMetadata.identity)
        try assertNoWriteTemporaryFiles(in: fixture.root)
        try assertNoWriteTemporaryFiles(in: movedRoot)
        try assertFixtureSentinel(fixture)
    }

    func testMissingWritePostflightRootReplacementCannotReportDurable() throws {
        let fixture = try makeWriteFixture(originalText: nil)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let movedRoot = fixture.parent.appendingPathComponent("moved-missing-postflight", isDirectory: true)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.root, to: movedRoot)
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            try "canonical replacement".write(
                to: fixture.destination,
                atomically: true,
                encoding: .utf8
            )
        }
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { event in
            if event == .postflight { mutation.run() }
        })

        let outcome = write(
            to: fixture,
            expecting: .missing,
            hooks: hooks
        )

        try mutation.rethrowIfFailed()
        let result = try XCTUnwrap(requireIndeterminate(outcome, reason: .namespaceChanged))
        let preparedMetadata = try XCTUnwrap(result.preparedMetadata)
        XCTAssertEqual(result.recoveryArtifact, .none)
        XCTAssertEqual(try writeText(at: fixture.destination), "canonical replacement")
        let movedDestination = movedRoot.appendingPathComponent("post.md")
        XCTAssertEqual(try writeText(at: movedDestination), "replacement bytes")
        XCTAssertEqual(try writeFileIdentity(at: movedDestination), preparedMetadata.identity)
        try assertNoWriteTemporaryFiles(in: fixture.root)
        try assertNoWriteTemporaryFiles(in: movedRoot)
        try assertFixtureSentinel(fixture)
    }
}
