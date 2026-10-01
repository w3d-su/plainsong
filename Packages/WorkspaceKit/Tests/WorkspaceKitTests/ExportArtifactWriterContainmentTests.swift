import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

/// A fake sandbox layout: `home` stands in for the user's home folder and
/// `home/Library/Containers/<id>/Data` for the app-private root that `NSHomeDirectory()` names
/// when the app runs sandboxed.
struct FakeSandbox {
    let home: URL
    let privateRoot: URL
    let temporaryItems: URL

    var homePath: String {
        WorkspaceRootContainment.normalizedDirectoryPath(home.path(percentEncoded: false))
    }

    /// Foundation's behavior inside the sandbox: a fresh directory under the container's
    /// pre-existing `tmp/TemporaryItems`.
    var provider: @Sendable (URL) throws -> URL {
        let temporaryItems = temporaryItems
        return { _ in
            let directory = temporaryItems.appendingPathComponent(
                "NSIRD_Plainsong_\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return directory
        }
    }
}

/// Item-replacement directory containment (D5 step 1, owner decision 2026-09-30) and the
/// identity-first, never-opened handling of the returned directory.
extension ExportArtifactWriterTests {
    func makeFakeSandbox(_ fixture: ExportWriterFixture) throws -> FakeSandbox {
        let home = fixture.base.appendingPathComponent("home", isDirectory: true)
        let privateRoot = home.appendingPathComponent("Library/Containers/app.plainsong.editor/Data", isDirectory: true)
        let temporaryItems = privateRoot.appendingPathComponent("tmp/TemporaryItems", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryItems, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: home.appendingPathComponent("notes.txt"))
        return FakeSandbox(home: home, privateRoot: privateRoot, temporaryItems: temporaryItems)
    }

    /// The chosen folder is the (fake) home folder, an ancestor of the app-private root. Staging
    /// below the root's pre-existing directories is accepted, and the home folder never gains an
    /// entry other than the leaf.
    func testStagingInsideTheAppPrivateRootIsAcceptedWhenTheChosenFolderIsItsAncestor() throws {
        let fixture = try makeExportFixture()
        let sandbox = try makeFakeSandbox(fixture)
        let before = try entries(in: sandbox.home)
        let destination = sandbox.home.appendingPathComponent("export.html", isDirectory: false)
        for replaces in [false, true] {
            let disposition: ExportArtifactDisposition = try replaces
                ? .replaceConfirmed(identity(at: destination))
                : .createNew
            let probe = ExportBoundaryProbe(watchedDirectory: sandbox.homePath)

            let outcome = export(
                "home export \(replaces)",
                to: destination,
                disposition: disposition,
                probe: probe,
                hooks: probe.hooks(stagingDirectory: sandbox.provider),
                appPrivateRoot: sandbox.privateRoot
            )

            XCTAssertNotNil(requireCommitted(outcome), "replaces: \(replaces)")
            XCTAssertEqual(try text(at: destination), "home export \(replaces)")
            XCTAssertFalse(probe.snapshots.isEmpty)
            for snapshot in probe.snapshots {
                XCTAssertTrue(Set(snapshot).isSubset(of: Set(before + ["export.html"])), "\(snapshot)")
            }
            XCTAssertEqual(try entries(in: sandbox.home), (before + ["export.html"]).sorted())
            XCTAssertEqual(try entries(in: sandbox.temporaryItems), [], "the staging directory is removed")
            XCTAssertFalse(probe.calls.contains { $0.operation == .open && $0.path == sandbox.homePath })
        }
    }

    func testNilPrivateRootKeepsRefusingStagingInsideTheChosenFolder() throws {
        let fixture = try makeExportFixture()
        let sandbox = try makeFakeSandbox(fixture)
        let before = try entries(in: sandbox.home)
        let probe = ExportBoundaryProbe()

        let outcome = export(
            to: sandbox.home.appendingPathComponent("export.html", isDirectory: false),
            disposition: .createNew,
            probe: probe,
            hooks: probe.hooks(stagingDirectory: sandbox.provider),
            appPrivateRoot: nil
        )

        XCTAssertEqual(outcome, .notCommitted(.stagingDirectoryInsideDestinationFolder))
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try entries(in: sandbox.temporaryItems), [], "the refused directory is removed")
        XCTAssertEqual(try entries(in: sandbox.home), before)
    }

    /// Everything else inside the chosen folder stays refused: a chosen folder equal to or
    /// inside the private root, a root that is only reachable through a symlink, and a directory
    /// under the chosen folder but outside the root.
    func testStagingInsideTheChosenFolderOutsideRuleBIsRefused() throws {
        let fixture = try makeExportFixture()
        let sandbox = try makeFakeSandbox(fixture)
        // The link lives inside the chosen folder, so the chosen folder is a proper ancestor of
        // its spelling: only the root proof (a directory under `AT_SYMLINK_NOFOLLOW_ANY`) refuses.
        let linkedRoot = sandbox.home.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: sandbox.privateRoot)
        let other = sandbox.home.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let outsideRoot: @Sendable (URL) throws -> URL = { _ in
            let directory = other.appendingPathComponent("NSIRD_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return directory
        }
        let tmp = sandbox.privateRoot.appendingPathComponent("tmp", isDirectory: true)
        let root = sandbox.privateRoot
        assertStagingRefusedInsideChosenFolder(
            chosen: root,
            provider: sandbox.provider,
            root: root,
            "chosen is the root"
        )
        assertStagingRefusedInsideChosenFolder(
            chosen: tmp,
            provider: sandbox.provider,
            root: root,
            "chosen inside the root"
        )
        let linkedProbe = assertStagingRefusedInsideChosenFolder(
            chosen: sandbox.home,
            provider: sandbox.provider,
            root: linkedRoot,
            "root only reachable through a symlink"
        )
        XCTAssertEqual(
            linkedProbe.calls(at: .canonicalizePrivateRoot).map(\.operation),
            [.fstatat],
            "the symlinked root fails its no-follow type check before any getattrlist"
        )
        assertStagingRefusedInsideChosenFolder(
            chosen: sandbox.home,
            provider: outsideRoot,
            root: root,
            "inside the chosen folder, outside the root"
        )
        XCTAssertEqual(try entries(in: sandbox.temporaryItems), [])
        XCTAssertEqual(try entries(in: other), [])
    }

    @discardableResult
    private func assertStagingRefusedInsideChosenFolder(
        chosen: URL,
        provider: @escaping @Sendable (URL) throws -> URL,
        root: URL?,
        _ label: String
    ) -> ExportBoundaryProbe {
        let probe = ExportBoundaryProbe()
        let destination = chosen.appendingPathComponent("export.html", isDirectory: false)

        let outcome = export(
            to: destination,
            disposition: .createNew,
            probe: probe,
            hooks: probe.hooks(stagingDirectory: provider),
            appPrivateRoot: root
        )

        XCTAssertEqual(outcome, .notCommitted(.stagingDirectoryInsideDestinationFolder), label)
        XCTAssertFalse(probe.createdStaging, label)
        XCTAssertFalse(exists(destination.path(percentEncoded: false)), label)
        return probe
    }

    /// The root is proven before Foundation is asked for a directory. A root that does not exist
    /// yet (here created by Foundation's `create: true` along with the staging directory) can
    /// never admit staging under rule (b).
    func testPrivateRootMustExistBeforeStagingBegins() throws {
        let fixture = try makeExportFixture()
        let home = fixture.base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let privateRoot = home.appendingPathComponent("Library/Containers/app.plainsong.editor/Data", isDirectory: true)
        let staging = privateRoot.appendingPathComponent("tmp/TemporaryItems/NSIRD_Plainsong_late", isDirectory: true)
        let probe = ExportBoundaryProbe()
        let hooks = probe.hooks(stagingDirectory: { _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            return staging
        })

        let outcome = export(
            to: home.appendingPathComponent("export.html", isDirectory: false),
            disposition: .createNew,
            probe: probe,
            hooks: hooks,
            appPrivateRoot: privateRoot
        )

        XCTAssertEqual(outcome, .notCommitted(.stagingDirectoryInsideDestinationFolder))
        let steps = probe.calls.map(\.step)
        let rootProof = try XCTUnwrap(steps.firstIndex(of: .canonicalizePrivateRoot))
        let staged = try XCTUnwrap(steps.firstIndex(of: .inspectStagingDirectory))
        XCTAssertLessThan(rootProof, staged, "the root is proven before the staging directory exists")
        XCTAssertFalse(probe.createdStaging)
        XCTAssertFalse(exists(staging.path(percentEncoded: false)), "the writer removes its refused directory")
        XCTAssertFalse(exists(home.appendingPathComponent("export.html").path(percentEncoded: false)))
    }

    /// The first identity observation of the returned directory fails with something other than
    /// `ENOENT`: its absence is unproven, so the outcome reports its exact path and is never a
    /// clean non-commit.
    func testUnobservableReturnedDirectoryIsReportedNotCalledAbsent() throws {
        let fixture = try makeExportFixture()
        let staging = fixture.base.appendingPathComponent("staging", isDirectory: true)
        let probe = ExportBoundaryProbe(failures: [.inspectStagingDirectory: EACCES])
        let hooks = probe.hooks(stagingDirectory: { _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        })

        let outcome = export(to: fixture.destination, disposition: .createNew, probe: probe, hooks: hooks)

        let result = try XCTUnwrap(requireIndeterminate(outcome))
        XCTAssertEqual(result.reason, .cleanupFailed)
        XCTAssertEqual(result.destinationState, .provenUnchanged)
        XCTAssertEqual(result.residue, .none)
        XCTAssertNil(result.stagingURL)
        XCTAssertEqual(
            result.itemReplacementDirectoryURL?.path(percentEncoded: false),
            staging.path(percentEncoded: false)
        )
        XCTAssertFalse(result.residueIsInPurgeableTemporaryFolder)
        XCTAssertEqual(probe.calls(at: .inspectStagingDirectory).count, 1)
        XCTAssertFalse(probe.calls.contains { $0.operation == .rmdir }, "nothing unobserved is removed")
        XCTAssertTrue(exists(staging.path(percentEncoded: false)))
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
    }

    /// Foundation's fallback directory beside the target is refused even with a private root;
    /// the chosen folder itself is compared by identity before anything touches it, and is never
    /// opened or removed.
    func testDirectChildAndTheChosenFolderItselfAreRefusedWithoutOpeningIt() throws {
        let fixture = try makeExportFixture()
        let sandbox = try makeFakeSandbox(fixture)
        let fallback = sandbox.home.appendingPathComponent("(A Document Being Saved By Plainsong)", isDirectory: true)
        struct Case {
            let label: String
            let provider: @Sendable (URL) throws -> URL
            let isRemoved: Bool
        }
        let home = sandbox.home
        let cases = [
            Case(label: "direct child", provider: { _ in
                try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
                return fallback
            }, isRemoved: true),
            Case(label: "chosen folder itself", provider: { _ in home }, isRemoved: false),
        ]
        for testCase in cases {
            let label = testCase.label
            let provider = testCase.provider
            let isRemoved = testCase.isRemoved
            let probe = ExportBoundaryProbe()

            let outcome = export(
                to: sandbox.home.appendingPathComponent("export.html", isDirectory: false),
                disposition: .createNew,
                probe: probe,
                hooks: probe.hooks(stagingDirectory: provider),
                appPrivateRoot: sandbox.privateRoot
            )

            XCTAssertEqual(outcome, .notCommitted(.stagingDirectoryInsideDestinationFolder), label)
            XCTAssertFalse(probe.calls.contains { $0.operation == .open }, "nothing is opened: \(label)")
            XCTAssertEqual(probe.calls.contains { $0.operation == .rmdir }, isRemoved, label)
        }
        XCTAssertFalse(exists(fallback.path(percentEncoded: false)))
        XCTAssertTrue(exists(sandbox.homePath), "the chosen folder is never removed")
        XCTAssertEqual(try entries(in: sandbox.home), ["Library", "notes.txt"])
    }

    /// Foundation already created the directory when canonicalization fails, so it is removed
    /// under an identity check, or reported by exact path when removal cannot be proven.
    func testStagingDirectoryThatCannotBeCanonicalizedIsRemovedOrReported() throws {
        for removalFails in [false, true] {
            let fixture = try makeExportFixture()
            let staging = fixture.base.appendingPathComponent("staging", isDirectory: true)
            var failures: [ExportArtifactWriterStep: Int32] = [.canonicalizeStagingDirectory: EIO]
            if removalFails {
                failures[.removeStagingDirectory] = EBUSY
            }
            let probe = ExportBoundaryProbe(failures: failures)
            let hooks = probe.hooks(stagingDirectory: { _ in
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                return staging
            })

            let outcome = export(to: fixture.destination, disposition: .createNew, probe: probe, hooks: hooks)

            XCTAssertFalse(probe.createdStaging)
            XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
            if removalFails {
                let result = try XCTUnwrap(requireIndeterminate(outcome))
                XCTAssertEqual(result.reason, .cleanupFailed)
                XCTAssertEqual(result.destinationState, .provenUnchanged)
                XCTAssertEqual(result.residue, .none)
                XCTAssertNil(result.stagingURL)
                XCTAssertEqual(
                    result.itemReplacementDirectoryURL?.path(percentEncoded: false),
                    staging.path(percentEncoded: false)
                )
                XCTAssertFalse(result.residueIsInPurgeableTemporaryFolder)
                XCTAssertEqual(try entries(in: staging), [])
            } else {
                XCTAssertEqual(outcome, .notCommitted(.stagingDirectoryUnavailable))
                XCTAssertFalse(exists(staging.path(percentEncoded: false)))
            }
        }
    }

    /// A refused staging directory that cannot be removed is never a clean non-commit: its exact
    /// path is reported and it is left in place, empty.
    func testRefusedStagingDirectoryThatCannotBeRemovedIsReportedExactly() throws {
        let fixture = try makeExportFixture()
        let fallback = fixture.directory.appendingPathComponent("(A Document Being Saved By Tests)", isDirectory: true)
        let probe = ExportBoundaryProbe(failures: [.removeStagingDirectory: EBUSY])
        let hooks = probe.hooks(stagingDirectory: { _ in
            try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
            return fallback
        })

        let outcome = export(to: fixture.destination, disposition: .createNew, probe: probe, hooks: hooks)

        let result = try XCTUnwrap(requireIndeterminate(outcome))
        XCTAssertEqual(result.reason, .cleanupFailed)
        XCTAssertEqual(result.selectedURL, fixture.destination)
        XCTAssertEqual(result.destinationState, .provenUnchanged)
        XCTAssertEqual(result.residue, .none)
        XCTAssertNil(result.stagingURL)
        XCTAssertEqual(
            result.itemReplacementDirectoryURL?.path(percentEncoded: false),
            fallback.path(percentEncoded: false)
        )
        XCTAssertFalse(result.residueIsInPurgeableTemporaryFolder)
        XCTAssertEqual(probe.calls(at: .removeStagingDirectory).count, 1, "no retry")
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try entries(in: fallback), [])
        XCTAssertEqual(
            try entries(in: fixture.directory),
            ["(A Document Being Saved By Tests)", Self.sentinelName].sorted()
        )
    }
}
