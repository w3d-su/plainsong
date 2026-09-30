import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

extension ExportArtifactWriterTests {
    func testStagingCreateWriteChmodAndSyncFailuresLeaveTheDestinationUntouched() throws {
        struct Fault {
            let step: ExportArtifactWriterStep
            let code: Int32
            let expected: ExportArtifactFailure
            /// Only a confirmed overwrite copies the displaced mode.
            var replacesOnly: Bool {
                step == .chmodStaged
            }
        }
        let faults = [
            Fault(step: .createStaged, code: EACCES, expected: .stagingNotPermitted(code: EACCES)),
            Fault(step: .createStaged, code: EPERM, expected: .stagingNotPermitted(code: EPERM)),
            Fault(step: .createStaged, code: ENOSPC, expected: .stagingUnavailable(code: ENOSPC)),
            Fault(step: .writeStaged, code: EIO, expected: .writeFailed(.unreadable)),
            Fault(step: .chmodStaged, code: EPERM, expected: .writeFailed(.unreadable)),
            Fault(step: .syncStaged, code: EIO, expected: .writeFailed(.durabilityFailed)),
        ]
        for fault in faults {
            let step = fault.step
            let code = fault.code
            let expected = fault.expected
            for replaces in fault.replacesOnly ? [true] : [false, true] {
                let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
                let disposition: ExportArtifactDisposition = try replaces
                    ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                    : .createNew
                let probe = ExportBoundaryProbe(failures: [step: code])

                let outcome = export(to: fixture.destination, disposition: disposition, probe: probe)

                let label = "\(step) \(code) replaces: \(replaces)"
                XCTAssertEqual(outcome, .notCommitted(expected), label)
                XCTAssertTrue(probe.calls(at: .publish).isEmpty, label)
                XCTAssertEqual(
                    probe.calls(at: .chmodStaged).isEmpty,
                    !replaces || step == .createStaged || step == .writeStaged,
                    label
                )
                XCTAssertFalse(exists(probe.stagedPath), label)
                XCTAssertFalse(exists(probe.stagingDirectoryPath), label)
                if replaces {
                    XCTAssertEqual(try text(at: fixture.destination), "original", label)
                    XCTAssertEqual(try identity(at: fixture.destination), fixture.originalIdentity, label)
                } else {
                    XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName], label)
                }
            }
        }
    }

    /// Real `EACCES`: a read-only item-replacement directory denies the exclusive create, and the
    /// writer reports it without any direct-write or alternate-directory fallback.
    func testRealStagingCreateDenialIsNotPermittedWithoutFallback() throws {
        let fixture = try makeExportFixture(originalText: "original")
        let staging = fixture.base.appendingPathComponent("read-only-staging", isDirectory: true)
        let probe = ExportBoundaryProbe()
        let hooks = probe.hooks(stagingDirectory: { _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            _ = Darwin.chmod(staging.path(percentEncoded: false), 0o500)
            return staging
        })
        defer { _ = Darwin.chmod(staging.path(percentEncoded: false), 0o700) }

        let outcome = try export(
            to: fixture.destination,
            disposition: .replaceConfirmed(XCTUnwrap(fixture.originalIdentity)),
            probe: probe,
            hooks: hooks
        )

        XCTAssertEqual(outcome, .notCommitted(.stagingNotPermitted(code: EACCES)))
        XCTAssertFalse(exists(staging.path(percentEncoded: false)), "the empty directory is removed")
        XCTAssertEqual(try text(at: fixture.destination), "original")
        XCTAssertEqual(try entries(in: fixture.directory), ["export.html", Self.sentinelName].sorted())
    }

    func testPublishFailuresRemoveStagingAndLeaveTheDestinationUnchanged() throws {
        struct Mapping {
            let code: Int32
            let exclusive: ExportArtifactFailure
            let swap: ExportArtifactFailure
        }
        let mappings = [
            Mapping(
                code: EACCES,
                exclusive: .publicationNotPermitted(code: EACCES),
                swap: .publicationNotPermitted(code: EACCES)
            ),
            Mapping(code: EEXIST, exclusive: .destinationAlreadyExists, swap: .destinationAlreadyExists),
            Mapping(code: ENOENT, exclusive: .namespaceChanged, swap: .destinationMissing),
            Mapping(code: ENOTSUP, exclusive: .unsupportedVolumeSemantics, swap: .unsupportedVolumeSemantics),
            Mapping(
                code: EXDEV,
                exclusive: .stagingDirectoryOnDifferentDevice,
                swap: .stagingDirectoryOnDifferentDevice
            ),
            Mapping(code: EIO, exclusive: .writeFailed(.unreadable), swap: .writeFailed(.unreadable)),
        ]
        for mapping in mappings {
            let code = mapping.code
            let exclusiveFailure = mapping.exclusive
            let swapFailure = mapping.swap
            for replaces in [false, true] {
                let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
                let disposition: ExportArtifactDisposition = try replaces
                    ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                    : .createNew
                let probe = ExportBoundaryProbe(failures: [.publish: code])

                let outcome = export(to: fixture.destination, disposition: disposition, probe: probe)

                let label = "errno \(code) replaces: \(replaces)"
                XCTAssertEqual(outcome, .notCommitted(replaces ? swapFailure : exclusiveFailure), label)
                XCTAssertEqual(probe.calls(at: .publish).count, 1, "no retry: \(label)")
                XCTAssertEqual(probe.calls(at: .unlinkStaged).count, 1, label)
                XCTAssertFalse(exists(probe.stagingDirectoryPath), label)
                if replaces {
                    XCTAssertEqual(try text(at: fixture.destination), "original", label)
                    XCTAssertEqual(try identity(at: fixture.destination), fixture.originalIdentity, label)
                } else {
                    XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName], label)
                }
            }
        }
    }

    func testPostflightMismatchReversesTheSwapOnlyAfterAnExactTwoNameProof() throws {
        let fixture = try makeExportFixture(originalText: "original")
        let original = try XCTUnwrap(fixture.originalIdentity)
        XCTAssertEqual(Darwin.chmod(fixture.destinationPath, 0o604), 0)
        let probe = ExportBoundaryProbe(failures: [.postflight: EIO])

        let outcome = export(
            "writer bytes",
            to: fixture.destination,
            disposition: .replaceConfirmed(original),
            probe: probe
        )

        XCTAssertEqual(outcome, .notCommitted(.namespaceChanged))
        XCTAssertEqual(probe.calls(at: .twoNameProof).count, 2)
        XCTAssertEqual(probe.calls(at: .reverseSwap).count, 1)
        XCTAssertEqual(try text(at: fixture.destination), "original")
        XCTAssertEqual(try identity(at: fixture.destination), original)
        XCTAssertEqual(try permissionBits(at: fixture.destination), 0o604)
        XCTAssertFalse(exists(probe.stagedPath), "the reversed writer bytes are removed")
        XCTAssertFalse(exists(probe.stagingDirectoryPath))
        XCTAssertEqual(try entries(in: fixture.directory), ["export.html", Self.sentinelName].sorted())
    }

    func testNewLeafPostflightMismatchIsIndeterminateAndNeverUnlinksTheLeafByPath() throws {
        let fixture = try makeExportFixture()
        let probe = ExportBoundaryProbe(failures: [.postflight: EIO])

        let outcome = export("writer bytes", to: fixture.destination, disposition: .createNew, probe: probe)

        let result = try XCTUnwrap(requireIndeterminate(outcome))
        XCTAssertEqual(result.reason, .namespaceChanged)
        XCTAssertEqual(result.selectedURL, fixture.destination)
        XCTAssertEqual(result.destinationState, .unknown)
        XCTAssertEqual(result.residue, .none)
        XCTAssertNil(result.stagingURL)
        XCTAssertNil(result.itemReplacementDirectoryURL, "the empty directory was proven removed")
        XCTAssertFalse(result.residueIsInPurgeableTemporaryFolder)
        XCTAssertTrue(probe.calls(at: .reverseSwap).isEmpty)
        XCTAssertEqual(try text(at: fixture.destination), "writer bytes")
    }

    func testReverseSwapFailurePreservesBothIdentitiesAndReportsExactPaths() throws {
        for failing in [ExportArtifactWriterStep.twoNameProof, .reverseSwap, .reversalProof] {
            let fixture = try makeExportFixture(originalText: "original")
            let original = try XCTUnwrap(fixture.originalIdentity)
            let probe = ExportBoundaryProbe(failures: [.postflight: EIO, failing: EIO])

            let outcome = export(
                "writer bytes",
                to: fixture.destination,
                disposition: .replaceConfirmed(original),
                probe: probe
            )

            let result = try XCTUnwrap(requireIndeterminate(outcome), "\(failing)")
            let staged = try XCTUnwrap(probe.stagedURL)
            XCTAssertEqual(result.reason, .namespaceChanged, "\(failing)")
            XCTAssertEqual(result.destinationState, .unknown, "\(failing)")
            XCTAssertEqual(result.stagingURL, staged, "\(failing)")
            XCTAssertEqual(result.itemReplacementDirectoryURL, probe.stagingDirectoryURL, "\(failing)")
            XCTAssertTrue(result.residueIsInPurgeableTemporaryFolder, "\(failing)")
            XCTAssertLessThanOrEqual(probe.calls(at: .reverseSwap).count, 1, "no automatic retry")
            if failing == .reversalProof {
                // The reversal ran but could not be proven: the original is back at the leaf.
                XCTAssertEqual(result.residue, .retained(staged, holding: .writerBytes))
                XCTAssertEqual(try identity(at: fixture.destination), original)
                XCTAssertEqual(try text(at: staged), "writer bytes")
            } else {
                XCTAssertEqual(result.residue, .retained(staged, holding: .displacedOriginal), "\(failing)")
                XCTAssertEqual(try text(at: fixture.destination), "writer bytes")
                XCTAssertEqual(try text(at: staged), "original")
                XCTAssertEqual(try identity(at: staged), original)
            }
            XCTAssertEqual(try entries(in: fixture.directory), ["export.html", Self.sentinelName].sorted())
        }
    }

    func testDisplacedUnlinkFailureReportsTheOriginalInThePurgeableTemporaryFolder() throws {
        for failing in [ExportArtifactWriterStep.unlinkDisplaced, .proveRemoved] {
            let fixture = try makeExportFixture(originalText: "original")
            let original = try XCTUnwrap(fixture.originalIdentity)
            let probe = ExportBoundaryProbe(failures: [failing: EIO])

            let outcome = export(
                "writer bytes",
                to: fixture.destination,
                disposition: .replaceConfirmed(original),
                probe: probe
            )

            let result = try XCTUnwrap(requireIndeterminate(outcome), "\(failing)")
            let staged = try XCTUnwrap(probe.stagedURL)
            XCTAssertEqual(result.reason, .cleanupFailed)
            XCTAssertEqual(result.destinationState, .holdsWriterBytes, "postflight proved the publication")
            XCTAssertEqual(
                result.residue,
                failing == .unlinkDisplaced ? .retained(staged, holding: .displacedOriginal) :
                    .removalIndeterminate(staged)
            )
            XCTAssertEqual(result.stagingURL, staged)
            XCTAssertEqual(result.itemReplacementDirectoryURL, probe.stagingDirectoryURL)
            XCTAssertTrue(result.residueIsInPurgeableTemporaryFolder)
            XCTAssertEqual(try text(at: fixture.destination), "writer bytes")
            XCTAssertEqual(try text(at: staged), "original")
            XCTAssertEqual(try identity(at: staged), original)
        }
    }

    func testStagingDirectoryRemovalFailureIsNeverSuccessOrACleanNonCommit() throws {
        for replaces in [false, true] {
            let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
            let disposition: ExportArtifactDisposition = try replaces
                ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                : .createNew
            let probe = ExportBoundaryProbe(failures: [.removeStagingDirectory: EBUSY])

            let result = try XCTUnwrap(requireIndeterminate(export(
                "writer bytes",
                to: fixture.destination,
                disposition: disposition,
                probe: probe
            )))

            XCTAssertEqual(result.reason, .cleanupFailed)
            XCTAssertEqual(result.destinationState, .holdsWriterBytes)
            XCTAssertEqual(result.residue, .none)
            XCTAssertNil(result.stagingURL, "the staged name was proven empty")
            XCTAssertEqual(result.itemReplacementDirectoryURL, probe.stagingDirectoryURL)
            XCTAssertFalse(result.residueIsInPurgeableTemporaryFolder)
            XCTAssertEqual(try text(at: fixture.destination), "writer bytes")
            XCTAssertEqual(try entries(in: XCTUnwrap(probe.stagingDirectoryURL)), [])
        }

        let fixture = try makeExportFixture()
        let probe = ExportBoundaryProbe(failures: [.syncStaged: EIO, .removeStagingDirectory: EBUSY])
        let result = try XCTUnwrap(requireIndeterminate(export(
            to: fixture.destination,
            disposition: .createNew,
            probe: probe
        )))
        XCTAssertEqual(result.destinationState, .provenUnchanged)
        XCTAssertEqual(result.residue, .none)
        XCTAssertEqual(result.itemReplacementDirectoryURL, probe.stagingDirectoryURL)
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
    }

    func testUnpublishedStagedFileThatCannotBeRemovedIsReportedExactly() throws {
        let fixture = try makeExportFixture(originalText: "original")
        let probe = ExportBoundaryProbe(failures: [.publish: EIO, .unlinkStaged: EIO])

        let outcome = try export(
            "writer bytes",
            to: fixture.destination,
            disposition: .replaceConfirmed(XCTUnwrap(fixture.originalIdentity)),
            probe: probe
        )

        let result = try XCTUnwrap(requireIndeterminate(outcome))
        let staged = try XCTUnwrap(probe.stagedURL)
        XCTAssertEqual(result.reason, .cleanupFailed)
        XCTAssertEqual(result.destinationState, .provenUnchanged)
        XCTAssertEqual(result.residue, .retained(staged, holding: .writerBytes))
        XCTAssertEqual(result.stagingURL, staged)
        XCTAssertEqual(result.itemReplacementDirectoryURL, probe.stagingDirectoryURL)
        XCTAssertEqual(try text(at: fixture.destination), "original")
        XCTAssertEqual(try text(at: staged), "writer bytes")
    }

    /// Success requires the staged name proven absent after `RENAME_EXCL`; an occupant that
    /// appears there is preserved and reported, never removed.
    func testCommittedNewLeafRequiresTheStagedNameProvenAbsent() throws {
        let fixture = try makeExportFixture()
        let probeBox = ProbeBox()
        let probe = ExportBoundaryProbe(races: [.postflight: {
            guard let staged = probeBox.probe?.stagedPath else { return }
            FileManager.default.createFile(atPath: staged, contents: Data("unrelated occupant".utf8))
        }])
        probeBox.probe = probe

        let outcome = export("artifact", to: fixture.destination, disposition: .createNew, probe: probe)

        let result = try XCTUnwrap(requireIndeterminate(outcome))
        let staged = try XCTUnwrap(probe.stagedURL)
        XCTAssertEqual(result.reason, .namespaceChanged)
        XCTAssertEqual(result.destinationState, .unknown)
        XCTAssertEqual(result.residue, .retained(staged, holding: .unknown))
        XCTAssertEqual(result.stagingURL, staged)
        XCTAssertEqual(result.itemReplacementDirectoryURL, probe.stagingDirectoryURL)
        XCTAssertEqual(try text(at: fixture.destination), "artifact")
        XCTAssertEqual(try text(at: staged), "unrelated occupant")
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
