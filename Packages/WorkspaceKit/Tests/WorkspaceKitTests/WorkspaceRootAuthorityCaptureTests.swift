import Foundation
@testable import WorkspaceKit
import XCTest

extension WorkspaceAnchoredFileSystemTests {
    func testAuthorityCaptureStaysOnOpenedRootWhenSelectedSymlinkRetargets() throws {
        let fixture = try makeAuthorityCaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try FileManager.default.createSymbolicLink(
            at: fixture.selected,
            withDestinationURL: fixture.rootA
        )
        let mutation = SynchronousMutation {
            try FileManager.default.removeItem(at: fixture.selected)
            try FileManager.default.createSymbolicLink(
                at: fixture.selected,
                withDestinationURL: fixture.rootB
            )
        }

        let authority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.selected,
            hooks: .init(eventHandler: { event in
                if event == .selectedRootOpened { mutation.run() }
            })
        )

        try mutation.rethrowIfFailed()
        XCTAssertEqual(try authorityText(authority), "root A")
        XCTAssertEqual(
            fixture.selected.resolvingSymlinksInPath().lastPathComponent,
            fixture.rootB.lastPathComponent
        )
    }

    func testAuthorityCaptureTracksOpenedDirectoryMove() throws {
        let fixture = try makeAuthorityCaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let moved = fixture.parent.appendingPathComponent("moved-A", isDirectory: true)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.rootA, to: moved)
        }

        let authority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.rootA,
            hooks: .init(eventHandler: { event in
                if event == .identitySampled { mutation.run() }
            })
        )

        try mutation.rethrowIfFailed()
        XCTAssertEqual(authority.canonicalRootURL.lastPathComponent, moved.lastPathComponent)
        XCTAssertEqual(try authorityText(authority), "root A")
    }

    func testAuthorityCaptureNeverBindsReplacementInstalledBeforeIdentitySampling() throws {
        let fixture = try makeAuthorityCaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let moved = fixture.parent.appendingPathComponent("opened-A", isDirectory: true)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.rootA, to: moved)
            try FileManager.default.createDirectory(
                at: fixture.rootA,
                withIntermediateDirectories: true
            )
            try "replacement".write(
                to: fixture.rootA.appendingPathComponent("post.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let authority = try WorkspaceFileSystemRootAuthority(
            rootURL: fixture.rootA,
            hooks: .init(eventHandler: { event in
                if event == .selectedRootOpened { mutation.run() }
            })
        )

        try mutation.rethrowIfFailed()
        XCTAssertEqual(try authorityText(authority), "root A")
        XCTAssertEqual(
            try String(
                contentsOf: fixture.rootA.appendingPathComponent("post.md"),
                encoding: .utf8
            ),
            "replacement"
        )
    }

    func testAuthorityCaptureRejectsReplacementAfterCanonicalPathDerivation() throws {
        let fixture = try makeAuthorityCaptureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let moved = fixture.parent.appendingPathComponent("derived-A", isDirectory: true)
        let mutation = SynchronousMutation {
            try FileManager.default.moveItem(at: fixture.rootA, to: moved)
            try FileManager.default.createDirectory(
                at: fixture.rootA,
                withIntermediateDirectories: true
            )
        }

        XCTAssertThrowsError(
            try WorkspaceFileSystemRootAuthority(
                rootURL: fixture.rootA,
                hooks: .init(eventHandler: { event in
                    if event == .canonicalPathDerived { mutation.run() }
                })
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceAnchoredFileSystemError, .namespaceChanged)
        }
        try mutation.rethrowIfFailed()
    }

    private struct AuthorityCaptureFixture {
        let parent: URL
        let rootA: URL
        let rootB: URL
        let selected: URL
    }

    private func makeAuthorityCaptureFixture() throws -> AuthorityCaptureFixture {
        let parent = try makeTemporaryDirectory()
        let rootA = parent.appendingPathComponent("A", isDirectory: true)
        let rootB = parent.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try "root A".write(
            to: rootA.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )
        try "root B".write(
            to: rootB.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )
        return AuthorityCaptureFixture(
            parent: parent,
            rootA: rootA,
            rootB: rootB,
            selected: parent.appendingPathComponent("selected", isDirectory: true)
        )
    }

    private func authorityText(_ authority: WorkspaceFileSystemRootAuthority) throws -> String {
        let location = try authority.location(relativePath: "post.md")
        let result = try WorkspaceAnchoredFileSystem.read(
            location,
            maximumByteCount: nil
        )
        return try XCTUnwrap(String(data: result.data, encoding: .utf8))
    }
}
