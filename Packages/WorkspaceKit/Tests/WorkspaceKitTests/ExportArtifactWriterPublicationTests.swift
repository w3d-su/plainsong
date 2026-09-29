import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

extension ExportArtifactWriterTests {
    func testNewLeafPublishesWithExclusiveRenameAndProvesStagingAbsent() throws {
        let fixture = try makeExportFixture()
        let probe = ExportBoundaryProbe(snapshotDirectory: fixture.directory)

        let outcome = export(
            "new artifact",
            to: fixture.destination,
            disposition: .createNew,
            hooks: probe.hooks()
        )

        let commit = try XCTUnwrap(requireCommitted(outcome))
        XCTAssertEqual(commit.selectedURL, fixture.destination)
        XCTAssertEqual(try text(at: fixture.destination), "new artifact")
        XCTAssertEqual(commit.metadata.identity, try identity(at: fixture.destination))
        XCTAssertEqual(commit.metadata.byteCount, Int64("new artifact".utf8.count))
        XCTAssertTrue(probe.events.contains(.willCommit(.exclusiveCreate)))
        XCTAssertFalse(probe.events.contains(.willCommit(.swap)))
        let stagingName = try XCTUnwrap(probe.stagingName)
        XCTAssertTrue(stagingName.hasPrefix(".plainsong-write-"))
        XCTAssertEqual(
            try entries(in: fixture.directory),
            ["export.html", Self.sentinelName].sorted()
        )
        XCTAssertEqual(try text(at: fixture.sentinel), "sentinel")
    }

    func testConfirmedReplacementSwapsExactIdentityWithoutTruncatingDisplacedInode() throws {
        let fixture = try makeExportFixture(originalText: "panel-approved original")
        let approved = try XCTUnwrap(fixture.originalIdentity)
        // A second name for the displaced inode outside the selected parent proves the swap
        // replaced a directory entry and never truncated or rewrote the displaced file.
        let outsideLink = fixture.base.appendingPathComponent("outside-link.html")
        try FileManager.default.linkItem(at: fixture.destination, to: outsideLink)
        let probe = ExportBoundaryProbe(snapshotDirectory: fixture.directory)

        let outcome = export(
            "replacement artifact",
            to: fixture.destination,
            disposition: .replaceConfirmed(approved),
            hooks: probe.hooks()
        )

        let commit = try XCTUnwrap(requireCommitted(outcome))
        XCTAssertEqual(try text(at: fixture.destination), "replacement artifact")
        XCTAssertNotEqual(commit.metadata.identity, approved)
        XCTAssertEqual(commit.metadata.identity, try identity(at: fixture.destination))
        XCTAssertTrue(probe.events.contains(.willCommit(.swap)))
        XCTAssertTrue(probe.events.contains(.displacedEntryCaptured))
        XCTAssertFalse(probe.events.contains(.willCommit(.exclusiveCreate)))
        XCTAssertEqual(try text(at: outsideLink), "panel-approved original")
        XCTAssertEqual(try identity(at: outsideLink), approved)
        XCTAssertEqual(try linkCount(at: outsideLink), 1)
        XCTAssertEqual(
            try entries(in: fixture.directory),
            ["export.html", Self.sentinelName].sorted()
        )
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

    func testAtMostOneOperationSiblingExistsAtEveryObservedBoundary() throws {
        for replaces in [false, true] {
            let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
            let probe = ExportBoundaryProbe(snapshotDirectory: fixture.directory)
            let disposition: ExportArtifactDisposition = try replaces
                ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                : .createNew

            XCTAssertNotNil(requireCommitted(export(
                to: fixture.destination,
                disposition: disposition,
                hooks: probe.hooks()
            )))

            let snapshots = probe.snapshots
            XCTAssertGreaterThan(snapshots.count, 5, "replaces: \(replaces)")
            for snapshot in snapshots {
                let siblings = snapshot.filter { $0.hasPrefix(".plainsong-") }
                XCTAssertLessThanOrEqual(siblings.count, 1, "replaces: \(replaces) \(snapshot)")
                XCTAssertTrue(
                    Set(snapshot).isSubset(of: Set(siblings + ["export.html", Self.sentinelName])),
                    "replaces: \(replaces) \(snapshot)"
                )
            }
            XCTAssertTrue(
                snapshots.contains { $0.contains { $0.hasPrefix(".plainsong-write-") } },
                "the staging file must be observed in the approved parent"
            )
            XCTAssertEqual(try operationSiblings(in: fixture.directory), [])
            XCTAssertEqual(try entries(in: fixture.base), ["selected"])
        }
    }

    func testWriterReleasesEveryDescriptorAfterEachOutcomeKind() throws {
        let fixture = try makeExportFixture(originalText: "original")
        let approved = try XCTUnwrap(fixture.originalIdentity)
        let counts = DescriptorCounts()
        let measuring = ExportArtifactWriterHooks(afterPreflight: {
            counts.append(exportOpenDescriptorCount(under: fixture.base))
        })
        XCTAssertEqual(exportOpenDescriptorCount(under: fixture.base), 0)

        XCTAssertNotNil(requireCommitted(export(
            to: fixture.destination,
            disposition: .replaceConfirmed(approved),
            hooks: measuring
        )))
        XCTAssertEqual(exportOpenDescriptorCount(under: fixture.base), 0)
        XCTAssertGreaterThan(counts.values.first ?? 0, 0, "preflight holds the parent descriptor")

        let refused = export(
            to: fixture.destination,
            disposition: .createNew
        )
        XCTAssertEqual(refused, .notCommitted(.destinationAlreadyExists))
        XCTAssertEqual(exportOpenDescriptorCount(under: fixture.base), 0)

        let current = try identity(at: fixture.destination)
        let failing = ExportBoundaryProbe(failures: [.renameSwap: .unreadable])
        XCTAssertEqual(
            export(to: fixture.destination, disposition: .replaceConfirmed(current), hooks: failing.hooks()),
            .notCommitted(.writeFailed(.unreadable))
        )
        XCTAssertEqual(exportOpenDescriptorCount(under: fixture.base), 0)

        let uncertain = ExportBoundaryProbe(
            failures: [.validateCommittedLeaf: .unreadable, .renameRollback: .unreadable]
        )
        XCTAssertNotNil(requireIndeterminate(export(
            to: fixture.destination,
            disposition: .replaceConfirmed(current),
            hooks: uncertain.hooks()
        )))
        XCTAssertEqual(exportOpenDescriptorCount(under: fixture.base), 0)
    }

    func testCommittedNewLeafRequiresStagingNameProvenAbsent() throws {
        let fixture = try makeExportFixture()
        let probe = ExportBoundaryProbe()
        let occupant = OccupantBox()
        let hooks = probe.hooks(afterPublication: { [probe] in
            guard let name = probe.stagingName else { return }
            let url = fixture.directory.appendingPathComponent(name, isDirectory: false)
            try? Data("unrelated occupant".utf8).write(to: url)
            occupant.url = url
        })

        let outcome = export("artifact", to: fixture.destination, disposition: .createNew, hooks: hooks)

        let result = try XCTUnwrap(requireIndeterminate(outcome))
        let occupantURL = try XCTUnwrap(occupant.url)
        XCTAssertEqual(result.reason, .namespaceChanged)
        XCTAssertEqual(result.selectedURL, fixture.destination)
        XCTAssertEqual(result.destinationState, .unknown)
        XCTAssertEqual(
            result.stagingURL?.path(percentEncoded: false),
            occupantURL.path(percentEncoded: false)
        )
        XCTAssertEqual(try text(at: fixture.destination), "artifact")
        XCTAssertEqual(try text(at: occupantURL), "unrelated occupant")
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

final class DescriptorCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    var values: [Int] {
        lock.withLock { stored }
    }

    func append(_ value: Int) {
        lock.withLock { stored.append(value) }
    }
}

final class OccupantBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    var url: URL? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
