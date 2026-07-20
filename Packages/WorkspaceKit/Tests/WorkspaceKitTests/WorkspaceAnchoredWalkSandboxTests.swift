import Foundation
@testable import WorkspaceKit
import XCTest

extension WorkspaceAnchoredFileSystemTests {
    /// Root-anchored walks must never open absolute ancestors of the granted root.
    ///
    /// Hosted tests run inside the app container, so a "/"-walk still succeeds under
    /// test and historically masked the shipped App Sandbox failure (EPERM opening
    /// components such as "Users" from a Powerbox-granted folder). Hook coverage
    /// asserts the production walk only opens relative components under the root.
    /// True Powerbox denial cannot be exercised in-process without a user-selected
    /// security-scoped grant outside the container.
    func testAnchoredWalkOpensOnlyRelativeComponentsUnderGrantedRoot() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let nested = root
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("alpha.md")
        try "body".write(to: file, atomically: true, encoding: .utf8)

        let recorder = AnchoredWalkEventRecorder()
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { recorder.handle($0) })

        let location = try WorkspaceFileSystemRootAuthority(rootURL: root)
            .location(relativePath: "docs/posts/alpha.md")
        let result = try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
            try WorkspaceAnchoredFileSystem.read(
                location,
                maximumByteCount: nil,
                hooks: hooks
            )
        }

        XCTAssertEqual(String(data: result.data, encoding: .utf8), "body")
        XCTAssertTrue(recorder.sawRootAnchored)
        XCTAssertTrue(
            recorder.rootAnchoredBeforeAnyComponent,
            "No component opens before the retained root is anchored"
        )
        XCTAssertEqual(recorder.openedComponents, ["docs", "posts"])

        // Absolute ancestors of the granted root (and the root leaf name itself) must
        // never appear as walk components — they are not relativePath intermediates.
        let absoluteRootComponents = Set(
            root.standardizedFileURL.pathComponents.filter { $0 != "/" }
        )
        XCTAssertTrue(
            Set(recorder.openedComponents).isDisjoint(with: absoluteRootComponents),
            "Walk opened absolute root/ancestor components: \(recorder.openedComponents)"
        )
    }

    /// Standalone (single-file / Save Copy) locations retain their own parent-directory
    /// authority; the walk still starts at that retained root, not "/".
    func testStandaloneLocationWalkOpensNoAncestorComponents() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("standalone.md")
        try "standalone body".write(to: file, atomically: true, encoding: .utf8)

        let recorder = AnchoredWalkEventRecorder()
        let hooks = WorkspaceAnchoredFileSystem.Hooks(eventHandler: { recorder.handle($0) })

        let location = try WorkspaceFileSystemLocation(fileURL: file)
        let result = try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
            try WorkspaceAnchoredFileSystem.read(
                location,
                maximumByteCount: nil,
                hooks: hooks
            )
        }

        XCTAssertEqual(String(data: result.data, encoding: .utf8), "standalone body")
        XCTAssertTrue(recorder.sawRootAnchored)
        // Parent is the authority root; relative path is only the leaf — no intermediate opens.
        XCTAssertEqual(recorder.openedComponents, [])
        let absoluteParentComponents = Set(
            parent.standardizedFileURL.pathComponents.filter { $0 != "/" }
        )
        XCTAssertTrue(Set(recorder.openedComponents).isDisjoint(with: absoluteParentComponents))
    }

    /// Permission-denied openat failures (EPERM/EACCES) map to `.unreadable`, matching
    /// the shipped sandbox denial that previously broke every workspace open when the
    /// walk attempted absolute ancestors above a Powerbox grant.
    func testPermissionDeniedComponentOpenMapsToUnreadable() throws {
        let root = try makeTemporaryDirectory()
        let nested = root.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "hidden".write(
            to: nested.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: nested.path
            )
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: nested.path
        )

        let location = try WorkspaceFileSystemRootAuthority(rootURL: root)
            .location(relativePath: "secret/post.md")

        XCTAssertThrowsError(
            try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
                try WorkspaceAnchoredFileSystem.read(
                    location,
                    maximumByteCount: nil,
                    hooks: .production
                )
            }
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceAnchoredFileSystemError,
                .unreadable,
                "EPERM/EACCES from openat must map to .unreadable (sandbox-denial shape)"
            )
        }
    }
}

private final class AnchoredWalkEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var openedComponents: [String] = []
    private(set) var sawRootAnchored = false
    private(set) var rootAnchoredBeforeAnyComponent = true

    func handle(_ event: WorkspaceAnchoredFileSystem.Event) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .rootAnchored:
            if !openedComponents.isEmpty {
                rootAnchoredBeforeAnyComponent = false
            }
            sawRootAnchored = true
        case let .componentOpened(component):
            if !sawRootAnchored {
                rootAnchoredBeforeAnyComponent = false
            }
            openedComponents.append(component)
        default:
            break
        }
    }
}
