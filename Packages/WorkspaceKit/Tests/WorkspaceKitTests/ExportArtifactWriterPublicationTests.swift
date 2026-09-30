import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

extension ExportArtifactWriterTests {
    func testNewLeafPublishesWithExclusiveRenameAndRemovesStaging() throws {
        let fixture = try makeExportFixture()
        let probe = ExportBoundaryProbe()

        let outcome = export("new artifact", to: fixture.destination, disposition: .createNew, probe: probe)

        let commit = try XCTUnwrap(requireCommitted(outcome))
        XCTAssertEqual(commit.selectedURL, fixture.destination)
        XCTAssertEqual(try text(at: fixture.destination), "new artifact")
        XCTAssertEqual(commit.metadata.identity, try identity(at: fixture.destination))
        XCTAssertEqual(commit.metadata.byteCount, Int64("new artifact".utf8.count))
        XCTAssertEqual(probe.calls(at: .publish).map(\.operation), [.rename])
        XCTAssertEqual(probe.calls(at: .publish).map(\.path), [fixture.destinationPath])
        XCTAssertTrue(probe.calls(at: .reverseSwap).isEmpty)
        XCTAssertTrue(probe.calls(at: .unlinkDisplaced).isEmpty, "RENAME_EXCL displaces nothing")
        let staging = try XCTUnwrap(probe.stagingDirectoryPath)
        XCTAssertFalse(exists(probe.stagedPath), "the staged name is proven absent")
        XCTAssertFalse(exists(staging), "the item-replacement directory is removed")
        XCTAssertEqual(try entries(in: fixture.directory), ["export.html", Self.sentinelName].sorted())
        XCTAssertEqual(try entries(in: fixture.base), ["selected"])
        XCTAssertEqual(try text(at: fixture.sentinel), "sentinel")
        assertTouchedOnlyLeafParentAndStaging(probe, fixture: fixture)
    }

    func testConfirmedOverwriteSwapsExactIdentityAndKeepsTheDisplacedMode() throws {
        let fixture = try makeExportFixture(originalText: "panel-approved original")
        let approved = try XCTUnwrap(fixture.originalIdentity)
        XCTAssertEqual(Darwin.chmod(fixture.destinationPath, 0o640), 0)
        // A second name for the displaced inode outside the chosen folder proves the swap
        // replaced a directory entry and never truncated or rewrote the displaced file.
        let outsideLink = fixture.base.appendingPathComponent("outside-link.html")
        try FileManager.default.linkItem(at: fixture.destination, to: outsideLink)
        let probe = ExportBoundaryProbe()

        let outcome = export(
            "replacement artifact",
            to: fixture.destination,
            disposition: .replaceConfirmed(approved),
            probe: probe
        )

        let commit = try XCTUnwrap(requireCommitted(outcome))
        XCTAssertEqual(try text(at: fixture.destination), "replacement artifact")
        XCTAssertNotEqual(commit.metadata.identity, approved)
        XCTAssertEqual(commit.metadata.identity, try identity(at: fixture.destination))
        XCTAssertEqual(try permissionBits(at: fixture.destination), 0o640, "Q3: the displaced mode is kept")
        XCTAssertEqual(probe.calls(at: .chmodStaged).count, 1)
        XCTAssertEqual(probe.calls(at: .publish).count, 1)
        XCTAssertEqual(probe.calls(at: .unlinkDisplaced).map(\.path), [probe.stagedPath].compactMap { $0 })
        XCTAssertTrue(probe.calls(at: .reverseSwap).isEmpty)
        XCTAssertEqual(try text(at: outsideLink), "panel-approved original")
        XCTAssertEqual(try identity(at: outsideLink), approved)
        XCTAssertEqual(try linkCount(at: outsideLink), 1, "the displaced name was unlinked")
        XCTAssertFalse(exists(probe.stagingDirectoryPath))
        XCTAssertEqual(try entries(in: fixture.directory), ["export.html", Self.sentinelName].sorted())
        assertTouchedOnlyLeafParentAndStaging(probe, fixture: fixture)
    }

    func testNewLeafModeIsTheUmaskDefault() throws {
        for mask: mode_t in [0o022, 0o027, 0o077] {
            let fixture = try makeExportFixture()
            let previous = Darwin.umask(mask)
            let outcome = export(to: fixture.destination, disposition: .createNew)
            Darwin.umask(previous)

            XCTAssertNotNil(requireCommitted(outcome))
            XCTAssertEqual(try permissionBits(at: fixture.destination), 0o666 & ~mask, "umask \(mask)")
        }
    }

    func testInspectDestinationReportsNewLeafAndPanelApprovedIdentity() throws {
        let fixture = try makeExportFixture()
        XCTAssertEqual(
            ExportArtifactWriter.inspectDestination(at: fixture.destination, kind: .html),
            .newLeaf
        )
        try Data("existing".utf8).write(to: fixture.destination)
        let existing = try identity(at: fixture.destination)

        let inspection = ExportArtifactWriter.inspectDestination(at: fixture.destination, kind: .html)

        XCTAssertEqual(inspection, .existingRegularFile(existing))
        guard case let .existingRegularFile(approved) = inspection else { return }
        XCTAssertNotNil(requireCommitted(export(
            "approved replacement",
            to: fixture.destination,
            disposition: .replaceConfirmed(approved)
        )))
        XCTAssertEqual(try text(at: fixture.destination), "approved replacement")
    }

    func testLeafInspectionComesFromLeafPathMetadata() throws {
        let fixture = try makeExportFixture()
        let parentIdentity = try identity(at: fixture.directory)
        let caseSensitive = try XCTUnwrap(
            fixture.directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames
        )

        let missing = try ExportArtifactWriter.inspectLeaf(at: fixture.destination).get()

        XCTAssertEqual(missing.state, .missing)
        XCTAssertEqual(missing.leafURL.path(percentEncoded: false), fixture.destinationPath)
        XCTAssertEqual(missing.parentIdentity, parentIdentity)
        XCTAssertEqual(missing.volumeIsCaseSensitive, caseSensitive)
        try Data("existing".utf8).write(to: fixture.destination)
        let existing = try ExportArtifactWriter.inspectLeaf(at: fixture.destination).get()
        XCTAssertEqual(existing.state, try .regular(identity(at: fixture.destination)))
        XCTAssertEqual(existing.leafURL, missing.leafURL)
        // A hard link is a different name for the same identity, not an alias: F_GETPATH keeps
        // the name the leaf was opened by.
        let link = fixture.directory.appendingPathComponent("link.md")
        try FileManager.default.linkItem(at: fixture.destination, to: link)
        let linked = try ExportArtifactWriter.inspectLeaf(at: link).get()
        XCTAssertEqual(linked.state, existing.state)
        XCTAssertEqual(linked.leafURL.path(percentEncoded: false), link.path(percentEncoded: false))
    }

    /// A save-panel grant covers only the leaf. Mode `0300` (write + search, no read) makes
    /// `open(parent, O_RDONLY)` fail while `fstatat` and `renameatx_np` into it still work, so the
    /// writer must publish without ever holding a parent descriptor.
    func testWriteOnlyParentPublishesWithoutEverOpeningTheChosenFolder() throws {
        for replaces in [false, true] {
            let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
            let parent = fixture.directoryPath
            XCTAssertEqual(Darwin.chmod(parent, 0o300), 0)
            defer { _ = Darwin.chmod(parent, 0o700) }
            let parentOpen = parent.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
            XCTAssertEqual(parentOpen, -1)
            XCTAssertEqual(errno, EACCES, "the simulated leaf-only grant cannot open the chosen folder")
            let inspection = ExportArtifactWriter.inspectDestination(at: fixture.destination, kind: .html)
            let disposition: ExportArtifactDisposition = try replaces
                ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                : .createNew
            XCTAssertEqual(
                inspection,
                try replaces ? .existingRegularFile(XCTUnwrap(fixture.originalIdentity)) : .newLeaf
            )
            let probe = ExportBoundaryProbe(watchedDirectory: parent)
            let counts = DescriptorCounts()

            let outcome = export(
                "leaf-only grant",
                to: fixture.destination,
                disposition: disposition,
                probe: probe,
                hooks: probe.hooks(afterPreflight: { counts.append(exportOpenDescriptorCount(exactly: parent)) })
            )

            XCTAssertNotNil(requireCommitted(outcome), "replaces: \(replaces)")
            XCTAssertEqual(Darwin.chmod(parent, 0o700), 0)
            XCTAssertEqual(try text(at: fixture.destination), "leaf-only grant")
            XCTAssertEqual(try entries(in: fixture.directory), ["export.html", Self.sentinelName].sorted())
            XCTAssertEqual(counts.values, [0])
            XCTAssertFalse(probe.watchedDescriptorCounts.isEmpty)
            XCTAssertTrue(probe.watchedDescriptorCounts.allSatisfy { $0 == 0 }, "no boundary holds the parent")
            XCTAssertFalse(probe.calls.contains { $0.path == parent && $0.operation != .fstatat })
            assertTouchedOnlyLeafParentAndStaging(probe, fixture: fixture)
        }
    }

    /// At every observed boundary of a successful new leaf or replacement, the chosen folder
    /// holds only its pre-existing entries and (after publication) the leaf. The single staged
    /// file lives only in the item-replacement directory, and both are gone on success.
    func testNoEntryOtherThanTheLeafIsEverCreatedInTheChosenFolder() throws {
        for replaces in [false, true] {
            let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
            let probe = ExportBoundaryProbe(watchedDirectory: fixture.directoryPath)
            let disposition: ExportArtifactDisposition = try replaces
                ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                : .createNew

            XCTAssertNotNil(requireCommitted(export(to: fixture.destination, disposition: disposition, probe: probe)))

            let snapshots = probe.snapshots
            XCTAssertGreaterThan(snapshots.count, 8, "replaces: \(replaces)")
            for snapshot in snapshots {
                XCTAssertTrue(
                    Set(snapshot).isSubset(of: ["export.html", Self.sentinelName]),
                    "replaces: \(replaces) \(snapshot)"
                )
            }
            let staged = try XCTUnwrap(probe.stagedPath)
            XCTAssertFalse(
                ExportArtifactWriter.pathLies(staged, inside: fixture.directoryPath, caseSensitive: false)
            )
            XCTAssertEqual(probe.calls(at: .createStaged).count, 1, "exactly one staged file")
            XCTAssertFalse(exists(staged))
            XCTAssertFalse(exists(probe.stagingDirectoryPath))
            XCTAssertEqual(try entries(in: fixture.directory), ["export.html", Self.sentinelName].sorted())
            XCTAssertEqual(try entries(in: fixture.base), ["selected"])
        }
    }

    func testWriterReleasesEveryDescriptorAfterEachOutcomeKind() throws {
        let fixture = try makeExportFixture(originalText: "original")
        let temporary = try WorkspaceFileSystemRootAuthority(rootURL: FileManager.default.temporaryDirectory)
            .canonicalRootURL.path(percentEncoded: false)
        let baseline = exportOpenDescriptorCount(under: temporary)

        let current = try XCTUnwrap(fixture.originalIdentity)
        XCTAssertNotNil(requireCommitted(export(to: fixture.destination, disposition: .replaceConfirmed(current))))
        XCTAssertEqual(exportOpenDescriptorCount(under: temporary), baseline)

        XCTAssertEqual(
            export(to: fixture.destination, disposition: .createNew),
            .notCommitted(.destinationAlreadyExists)
        )
        XCTAssertEqual(exportOpenDescriptorCount(under: temporary), baseline)

        let replaced = try identity(at: fixture.destination)
        XCTAssertEqual(
            export(
                to: fixture.destination,
                disposition: .replaceConfirmed(replaced),
                probe: ExportBoundaryProbe(failures: [.syncStaged: EIO])
            ),
            .notCommitted(.writeFailed(.durabilityFailed))
        )
        XCTAssertEqual(exportOpenDescriptorCount(under: temporary), baseline)

        XCTAssertNotNil(requireIndeterminate(export(
            to: fixture.destination,
            disposition: .replaceConfirmed(replaced),
            probe: ExportBoundaryProbe(failures: [.postflight: EIO, .reverseSwap: EIO])
        )))
        XCTAssertEqual(exportOpenDescriptorCount(under: temporary), baseline)
    }

    func testExtensionMatchIsASCIICaseInsensitiveAndKindSpecific() throws {
        let fixture = try makeExportFixture(leaf: "Report.PDF")
        XCTAssertEqual(
            export(to: fixture.destination, kind: .html, disposition: .createNew),
            .notCommitted(.unsupportedExtension)
        )
        XCTAssertNotNil(requireCommitted(export(
            "%PDF-1.7",
            to: fixture.destination,
            kind: .pdf,
            disposition: .createNew
        )))
        XCTAssertEqual(try text(at: fixture.destination), "%PDF-1.7")
        let htm = fixture.directory.appendingPathComponent("page.HTM")
        XCTAssertNotNil(requireCommitted(export(to: htm, disposition: .createNew)))
    }

    func testCancelledOperationWritesNothing() async throws {
        let fixture = try makeExportFixture()
        let destination = fixture.destination
        let task = Task { [self] () -> ExportArtifactWriteOutcome in
            while !Task.isCancelled {
                await Task.yield()
            }
            return export(to: destination, disposition: .createNew)
        }
        task.cancel()

        let outcome = await task.value

        XCTAssertEqual(outcome, .notCommitted(.cancelled))
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
    }
}
