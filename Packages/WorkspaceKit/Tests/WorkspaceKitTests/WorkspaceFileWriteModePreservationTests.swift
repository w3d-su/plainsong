import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

/// Save preserves a replaced file's `rwx` permission bits, but never its setuid, setgid, or
/// sticky bits. This is the same mask the export writer applies (Export PR E2, Q3 hardening).
extension WorkspaceAnchoredFileSystemTests {
    func testSaveOverSetuidFileEndsWithoutTheSetuidBit() throws {
        try assertSavedMode(afterChmod: 0o4755, expected: 0o755)
    }

    func testSaveOverSetgidFileEndsWithoutTheSetgidBit() throws {
        try assertSavedMode(afterChmod: 0o2755, expected: 0o755)
    }

    func testSaveOverStickyFileEndsWithoutTheStickyBit() throws {
        try assertSavedMode(afterChmod: 0o1644, expected: 0o644)
    }

    func testSavePreservesOrdinaryPermissionBits() throws {
        try assertSavedMode(afterChmod: 0o640, expected: 0o640)
    }

    func testEveryExistingTargetExpectationMasksSpecialBits() throws {
        for kind in ExistingExpectationKind.allCases {
            try assertSavedMode(afterChmod: 0o4755, expected: 0o755, expectationKind: kind)
        }
    }

    private enum ExistingExpectationKind: String, CaseIterable {
        case existing
        case existingContent
        case existingOrMissing

        func expectation(
            for fixture: WorkspaceWriteFixture
        ) throws -> WorkspaceNoFollowFileWriteExpectation {
            let identity = try XCTUnwrap(fixture.originalIdentity)
            switch self {
            case .existing:
                return .existing(identity)
            case .existingContent:
                return .existingContent(
                    identity,
                    sha256Digest: WorkspaceAnchoredFileSystem.sha256Digest(Data("original".utf8))
                )
            case .existingOrMissing:
                return .existingOrMissing
            }
        }
    }

    private func assertSavedMode(
        afterChmod requested: mode_t,
        expected: mode_t,
        expectationKind: ExistingExpectationKind = .existing,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = try makeWriteFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        XCTAssertEqual(Darwin.chmod(fixture.destination.path, requested), 0, file: file, line: line)
        let original = try noFollowStatus(at: fixture.destination).st_mode & mode_t(0o7777)
        XCTAssertEqual(
            original,
            requested,
            "the fixture must carry exactly the requested mode",
            file: file,
            line: line
        )

        let outcome = try write(
            to: fixture,
            expecting: expectationKind.expectation(for: fixture)
        )

        let durable = try XCTUnwrap(requireDurable(outcome, file: file, line: line))
        XCTAssertEqual(durable.cleanupState, .none, file: file, line: line)
        XCTAssertEqual(try writeText(at: fixture.destination), "replacement bytes", file: file, line: line)
        let published = try noFollowStatus(at: fixture.destination)
        let requestedOctal = String(requested, radix: 8)
        let expectedOctal = String(expected, radix: 8)
        XCTAssertEqual(
            published.st_mode & mode_t(0o7777),
            expected,
            "\(expectationKind.rawValue): 0o\(requestedOctal) must publish as 0o\(expectedOctal)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            published.st_mode & mode_t(S_IFMT),
            mode_t(S_IFREG),
            file: file,
            line: line
        )
        try assertNoWriteArtifacts(for: fixture, file: file, line: line)
        try assertFixtureSentinel(fixture, file: file, line: line)
    }
}
