import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

extension ExportArtifactWriterTests {
    func testStagingCreateWriteAndSyncFailuresProveDestinationUntouched() throws {
        let steps: [(WorkspaceAnchoredFileSystem.InjectedCall, WorkspaceAnchoredFileSystemError)] = [
            (.createTemporary, .unreadable),
            (.writeTemporary, .unreadable),
            (.syncTemporary, .durabilityFailed),
        ]
        for (call, error) in steps {
            for replaces in [false, true] {
                let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
                let disposition: ExportArtifactDisposition = try replaces
                    ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                    : .createNew
                let probe = ExportBoundaryProbe(failures: [call: error])

                let outcome = export(to: fixture.destination, disposition: disposition, hooks: probe.hooks())

                XCTAssertEqual(outcome, .notCommitted(.writeFailed(error)), "\(call) replaces: \(replaces)")
                XCTAssertEqual(probe.createdStaging, call != .createTemporary, "\(call)")
                XCTAssertFalse(probe.calls.contains(.renameExclusive), "\(call)")
                XCTAssertFalse(probe.calls.contains(.renameSwap), "\(call)")
                XCTAssertEqual(try operationSiblings(in: fixture.directory), [], "\(call)")
                if replaces {
                    XCTAssertEqual(try text(at: fixture.destination), "original")
                    XCTAssertEqual(try identity(at: fixture.destination), fixture.originalIdentity)
                } else {
                    XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
                }
            }
        }
    }

    func testPublishFailuresRemoveStagingAndLeaveDestinationUnchanged() throws {
        for replaces in [false, true] {
            let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
            let call: WorkspaceAnchoredFileSystem.InjectedCall = replaces ? .renameSwap : .renameExclusive
            let disposition: ExportArtifactDisposition = try replaces
                ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                : .createNew
            let probe = ExportBoundaryProbe(failures: [call: .unreadable])

            let outcome = export(to: fixture.destination, disposition: disposition, hooks: probe.hooks())

            XCTAssertEqual(outcome, .notCommitted(.writeFailed(.unreadable)), "replaces: \(replaces)")
            XCTAssertEqual(probe.calls.filter { $0 == call }.count, 1, "no retry")
            XCTAssertFalse(probe.events.contains(.didCommit(replaces ? .swap : .exclusiveCreate)))
            XCTAssertEqual(try operationSiblings(in: fixture.directory), [])
            if replaces {
                XCTAssertEqual(try text(at: fixture.destination), "original")
                XCTAssertEqual(try identity(at: fixture.destination), fixture.originalIdentity)
            } else {
                XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
            }
        }
    }

    func testPostflightReadAndParentSyncFailuresRollBackToProvenNonCommit() throws {
        let steps: [WorkspaceAnchoredFileSystem.InjectedCall] = [
            .validateCommittedLeaf,
            .syncCommittedDirectory,
        ]
        for call in steps {
            for replaces in [false, true] {
                let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
                let disposition: ExportArtifactDisposition = try replaces
                    ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                    : .createNew
                let probe = ExportBoundaryProbe(failures: [call: .unreadable])

                let outcome = export(to: fixture.destination, disposition: disposition, hooks: probe.hooks())

                XCTAssertEqual(outcome, .notCommitted(.writeFailed(.unreadable)), "\(call) replaces: \(replaces)")
                XCTAssertTrue(probe.events.contains(.didRollback), "\(call) replaces: \(replaces)")
                XCTAssertEqual(try operationSiblings(in: fixture.directory), [])
                if replaces {
                    XCTAssertEqual(probe.calls.filter { $0 == .renameRollback }.count, 1)
                    XCTAssertEqual(try text(at: fixture.destination), "original")
                    XCTAssertEqual(try identity(at: fixture.destination), fixture.originalIdentity)
                } else {
                    XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
                }
            }
        }
    }

    func testReverseSwapFailurePreservesBothIdentitiesAndReportsExactPaths() throws {
        for call in [WorkspaceAnchoredFileSystem.InjectedCall.renameRollback, .renameRollbackAfterValidation] {
            let fixture = try makeExportFixture(originalText: "original")
            let original = try XCTUnwrap(fixture.originalIdentity)
            let probe = ExportBoundaryProbe(failures: [.validateCommittedLeaf: .unreadable, call: .unreadable])

            let outcome = export(
                "writer bytes",
                to: fixture.destination,
                disposition: .replaceConfirmed(original),
                hooks: probe.hooks()
            )

            let result = try XCTUnwrap(requireIndeterminate(outcome))
            let staging = try XCTUnwrap(stagingURL(probe.stagingName, in: fixture))
            XCTAssertEqual(result.selectedURL, fixture.destination)
            XCTAssertEqual(result.destinationState, .unknown)
            XCTAssertEqual(result.residue.url?.path(percentEncoded: false), staging.path(percentEncoded: false))
            XCTAssertEqual(result.stagingURL?.path(percentEncoded: false), staging.path(percentEncoded: false))
            guard case .retained = result.residue else {
                return XCTFail("displaced identity must be observed at the staging path: \(result)")
            }
            XCTAssertEqual(try text(at: fixture.destination), "writer bytes")
            XCTAssertEqual(try text(at: staging), "original")
            XCTAssertEqual(try identity(at: staging), original)
            XCTAssertEqual(probe.calls.filter { $0 == call }.count, 1, "no automatic retry")
            XCTAssertFalse(probe.events.contains(.didRollback))
        }
    }

    func testReverseSwapSyncFailureReportsRestoredDestinationAndRetainedWriterStaging() throws {
        let fixture = try makeExportFixture(originalText: "original")
        let original = try XCTUnwrap(fixture.originalIdentity)
        let probe = ExportBoundaryProbe(
            failures: [.validateCommittedLeaf: .unreadable, .syncRollbackDirectory: .durabilityFailed]
        )

        let outcome = export(
            "writer bytes",
            to: fixture.destination,
            disposition: .replaceConfirmed(original),
            hooks: probe.hooks()
        )

        let result = try XCTUnwrap(requireIndeterminate(outcome))
        let staging = try XCTUnwrap(stagingURL(probe.stagingName, in: fixture))
        XCTAssertEqual(result.reason, .durabilityFailed)
        XCTAssertEqual(result.destinationState, .unknown)
        guard case let .retained(retained) = result.residue else {
            return XCTFail("writer identity must be observed at the staging path: \(result)")
        }
        XCTAssertEqual(retained.path(percentEncoded: false), staging.path(percentEncoded: false))
        XCTAssertEqual(result.stagingURL, retained)
        XCTAssertEqual(try text(at: fixture.destination), "original")
        XCTAssertEqual(try identity(at: fixture.destination), original)
        XCTAssertEqual(try text(at: staging), "writer bytes")
    }

    func testCreatedDestinationRollbackFailureIsIndeterminateAndKeepsWriterBytes() throws {
        let fixture = try makeExportFixture()
        let probe = ExportBoundaryProbe(
            failures: [.validateCommittedLeaf: .unreadable, .unlinkCreatedDestination: .cleanupFailed]
        )

        let outcome = export("writer bytes", to: fixture.destination, disposition: .createNew, hooks: probe.hooks())

        let result = try XCTUnwrap(requireIndeterminate(outcome))
        XCTAssertEqual(result.selectedURL, fixture.destination)
        XCTAssertEqual(result.destinationState, .unknown)
        XCTAssertEqual(
            result.residue.url?.path(percentEncoded: false),
            fixture.destination.path(percentEncoded: false)
        )
        XCTAssertEqual(
            result.stagingURL?.path(percentEncoded: false),
            stagingURL(probe.stagingName, in: fixture)?.path(percentEncoded: false),
            "a residue at the selected leaf leaves the exact staging path reported as unproven"
        )
        XCTAssertEqual(try text(at: fixture.destination), "writer bytes")
        XCTAssertEqual(try operationSiblings(in: fixture.directory), [])
    }

    func testDisplacedCleanupFailuresAreIndeterminateEvenThoughWriterBytesArePublished() throws {
        let steps: [(WorkspaceAnchoredFileSystem.InjectedCall, WorkspaceAnchoredFileSystemError)] = [
            (.unlinkRollbackArtifact, .cleanupFailed),
            (.unlinkQuarantinedArtifact, .cleanupFailed),
            (.syncCleanupDirectory, .durabilityFailed),
        ]
        for (call, error) in steps {
            let fixture = try makeExportFixture(originalText: "original")
            let original = try XCTUnwrap(fixture.originalIdentity)
            let probe = ExportBoundaryProbe(failures: [call: error])

            let outcome = export(
                "writer bytes",
                to: fixture.destination,
                disposition: .replaceConfirmed(original),
                hooks: probe.hooks()
            )

            let result = try XCTUnwrap(requireIndeterminate(outcome), "\(call)")
            XCTAssertEqual(result.reason, .cleanupFailed, "\(call)")
            XCTAssertEqual(result.destinationState, .holdsWriterBytes, "\(call)")
            XCTAssertEqual(try text(at: fixture.destination), "writer bytes", "\(call)")
            let stagingPath = try XCTUnwrap(result.stagingURL, "\(call)")
            XCTAssertEqual(result.residue.url, stagingPath, "\(call)")
            XCTAssertTrue(stagingPath.lastPathComponent.hasPrefix(".plainsong-"), "\(call)")
            let siblings = try operationSiblings(in: fixture.directory)
            switch result.residue {
            case .retained:
                XCTAssertEqual(siblings, [stagingPath.lastPathComponent], "\(call)")
                XCTAssertEqual(try text(at: stagingPath), "original", "\(call)")
                XCTAssertEqual(try identity(at: stagingPath), original, "\(call)")
            case .removalIndeterminate:
                XCTAssertEqual(call, .syncCleanupDirectory)
                XCTAssertEqual(siblings, [], "the unlink completed but its directory sync did not")
            case .none:
                XCTFail("cleanup uncertainty must name an exact path: \(call)")
            }
        }
    }

    func testUnexpectedDisplacedEntryPreventsReverseSwapAndPreservesBothIdentities() throws {
        let fixture = try makeExportFixture(originalText: "original")
        let original = try XCTUnwrap(fixture.originalIdentity)
        let movedOriginal = fixture.base.appendingPathComponent("moved-original.html")
        let probeBox = ProbeBox()
        let probe = ExportBoundaryProbe(races: [
            .afterRenameSwap: {
                guard let name = probeBox.probe?.stagingName else { return }
                let staging = fixture.directory.appendingPathComponent(name, isDirectory: false)
                try? FileManager.default.moveItem(at: staging, to: movedOriginal)
                try? Data("racer".utf8).write(to: staging)
            },
        ])
        probeBox.probe = probe

        let outcome = export(
            "writer bytes",
            to: fixture.destination,
            disposition: .replaceConfirmed(original),
            hooks: probe.hooks()
        )

        let result = try XCTUnwrap(requireIndeterminate(outcome))
        let staging = try XCTUnwrap(stagingURL(probe.stagingName, in: fixture))
        XCTAssertEqual(result.destinationState, .unknown)
        guard case let .removalIndeterminate(uncertain) = result.residue else {
            return XCTFail("an unexpected displaced entry must stay removal-indeterminate: \(result)")
        }
        XCTAssertEqual(uncertain.path(percentEncoded: false), staging.path(percentEncoded: false))
        XCTAssertEqual(result.stagingURL, uncertain)
        XCTAssertFalse(probe.calls.contains(.renameRollback), "no reverse swap without two-name proof")
        XCTAssertEqual(try text(at: fixture.destination), "writer bytes")
        XCTAssertEqual(try text(at: staging), "racer")
        XCTAssertEqual(try text(at: movedOriginal), "original")
        XCTAssertEqual(try identity(at: movedOriginal), original)
    }

    func testIdentityAndTypeRacesAfterInspectionFailClosedWithoutTouchingRacer() throws {
        enum Race: CaseIterable {
            case replacedFile, directory, symbolicLink, createdRacer
        }
        for race in Race.allCases {
            let fixture = try makeExportFixture(originalText: race == .createdRacer ? nil : "original")
            let disposition: ExportArtifactDisposition = try race == .createdRacer
                ? .createNew
                : .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
            let destination = fixture.destination
            let outside = fixture.base.appendingPathComponent("outside.html")
            try Data("outside".utf8).write(to: outside)
            let hooks = ExportArtifactWriterHooks(afterPreflight: {
                switch race {
                case .replacedFile:
                    try? FileManager.default.removeItem(at: destination)
                    try? Data("racer".utf8).write(to: destination)
                case .directory:
                    try? FileManager.default.removeItem(at: destination)
                    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                case .symbolicLink:
                    try? FileManager.default.removeItem(at: destination)
                    try? FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
                case .createdRacer:
                    try? Data("racer".utf8).write(to: destination)
                }
            })

            let outcome = export(to: destination, disposition: disposition, hooks: hooks)

            let expected: ExportArtifactFailure = switch race {
            case .replacedFile, .createdRacer: .destinationIdentityChanged
            case .directory: .nonRegularDestination
            case .symbolicLink: .symbolicLinkDestination
            }
            XCTAssertEqual(outcome, .notCommitted(expected), "\(race)")
            XCTAssertEqual(try operationSiblings(in: fixture.directory), [], "\(race)")
            XCTAssertEqual(try text(at: outside), "outside", "\(race)")
            if race == .replacedFile || race == .createdRacer {
                XCTAssertEqual(try text(at: destination), "racer", "\(race)")
            }
        }
    }

    /// A racer that replaces the selected leaf at the last instrumented boundary is never
    /// overwritten. Because the pre-operation destination can no longer be re-proven after
    /// staging cleanup, the audited primitive reports uncertainty rather than a clean non-commit.
    func testRaceAtFinalPublishBoundaryNeverOverwritesRacerOrClaimsSuccess() throws {
        for replaces in [false, true] {
            let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
            let destination = fixture.destination
            let call: WorkspaceAnchoredFileSystem.InjectedCall = replaces ? .renameSwap : .renameExclusive
            let disposition: ExportArtifactDisposition = try replaces
                ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                : .createNew
            let probe = ExportBoundaryProbe(races: [
                call: {
                    try? FileManager.default.removeItem(at: destination)
                    try? Data("final racer".utf8).write(to: destination)
                },
            ])

            let outcome = export(to: destination, disposition: disposition, hooks: probe.hooks())

            let result = try XCTUnwrap(requireIndeterminate(outcome), "replaces: \(replaces)")
            XCTAssertEqual(result.reason, .changedIdentity, "replaces: \(replaces)")
            XCTAssertEqual(result.destinationState, .unknown, "replaces: \(replaces)")
            XCTAssertEqual(result.residue, .none, "staging was removed under identity proof")
            XCTAssertNil(result.stagingURL)
            XCTAssertEqual(probe.calls.filter { $0 == call }.count, 1, "no retry")
            XCTAssertFalse(probe.events.contains(.didCommit(replaces ? .swap : .exclusiveCreate)))
            XCTAssertEqual(try text(at: destination), "final racer", "replaces: \(replaces)")
            XCTAssertEqual(try operationSiblings(in: fixture.directory), [], "replaces: \(replaces)")
        }
    }
}

final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ExportBoundaryProbe?

    var probe: ExportBoundaryProbe? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
