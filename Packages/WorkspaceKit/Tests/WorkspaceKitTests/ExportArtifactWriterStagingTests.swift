import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

/// Item-replacement staging (D5 step 1), Q1 coordination, and leaf races around staging.
extension ExportArtifactWriterTests {
    func testFoundationItemReplacementDirectoryIsOperationPrivateOnTheDestinationDevice() throws {
        let fixture = try makeExportFixture()
        let probe = ExportBoundaryProbe()
        let observed = DescriptorCounts()
        let hooks = probe.hooks(afterPublication: { [probe] in
            guard let staging = probe.stagingDirectoryPath,
                  let status = try? self.status(at: staging)
            else { return }
            observed.append(Int(status.st_dev))
        })

        XCTAssertNotNil(requireCommitted(export(
            to: fixture.destination,
            disposition: .createNew,
            probe: probe,
            hooks: hooks
        )))

        let staging = try XCTUnwrap(probe.stagingDirectoryPath)
        XCTAssertFalse(ExportArtifactWriter.pathLies(staging, inside: fixture.directoryPath, caseSensitive: false))
        XCTAssertTrue(staging.contains("/TemporaryItems/"), staging)
        XCTAssertEqual(observed.values, try [Int(status(at: fixture.directoryPath).st_dev)])
        XCTAssertFalse(exists(staging))

        let second = ExportBoundaryProbe()
        let replaced = try identity(at: fixture.destination)
        XCTAssertNotNil(requireCommitted(export(
            to: fixture.destination,
            disposition: .replaceConfirmed(replaced),
            probe: second
        )))
        XCTAssertNotEqual(second.stagingDirectoryPath, staging, "each operation gets its own directory")
        XCTAssertFalse(exists(second.stagingDirectoryPath))
    }

    func testUnavailableItemReplacementDirectoryFailsClosedWithoutFallback() throws {
        let fixture = try makeExportFixture()
        let notADirectory = fixture.base.appendingPathComponent("plain-file")
        try Data("file".utf8).write(to: notADirectory)
        let providers: [@Sendable (URL) throws -> URL] = [
            { _ in throw CocoaError(.fileWriteNoPermission) },
            { _ in fixture.base.appendingPathComponent("missing", isDirectory: true) },
            { _ in notADirectory },
        ]
        for provider in providers {
            let probe = ExportBoundaryProbe()
            XCTAssertEqual(
                export(
                    to: fixture.destination,
                    disposition: .createNew,
                    probe: probe,
                    hooks: probe.hooks(stagingDirectory: provider)
                ),
                .notCommitted(.stagingDirectoryUnavailable)
            )
            XCTAssertFalse(probe.createdStaging)
            XCTAssertTrue(probe.calls(at: .publish).isEmpty)
        }
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
        XCTAssertEqual(try entries(in: fixture.base), ["plain-file", "selected"])
    }

    /// Foundation's fallback creates "(A Document Being Saved By …)" beside the target before any
    /// check can run. The writer refuses it (and anything deeper), removes only that empty
    /// directory, and never removes the chosen folder itself.
    func testItemReplacementDirectoryInsideTheChosenFolderIsRefusedAndRemoved() throws {
        let fixture = try makeExportFixture()
        let sibling = fixture.directory.appendingPathComponent("(A Document Being Saved By Tests)", isDirectory: true)
        let nestedParent = fixture.directory.appendingPathComponent("nested", isDirectory: true)
        let nested = nestedParent.appendingPathComponent("deeper", isDirectory: true)
        for directory in [sibling, nested] {
            let probe = ExportBoundaryProbe()
            let hooks = probe.hooks(stagingDirectory: { _ in
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return directory
            })

            XCTAssertEqual(
                export(to: fixture.destination, disposition: .createNew, probe: probe, hooks: hooks),
                .notCommitted(.stagingDirectoryInsideDestinationFolder)
            )
            XCTAssertFalse(probe.createdStaging)
            XCTAssertFalse(exists(directory.path(percentEncoded: false)), "the refused directory is removed")
            XCTAssertFalse(
                probe.calls.contains { $0.operation == .open },
                "nothing is opened, the chosen folder least of all"
            )
        }
        XCTAssertEqual(try entries(in: fixture.directory), ["nested", Self.sentinelName].sorted())
        XCTAssertEqual(try entries(in: nestedParent), [])

        let empty = fixture.base.appendingPathComponent("empty-chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let probe = ExportBoundaryProbe()
        XCTAssertEqual(
            export(
                to: empty.appendingPathComponent("export.html", isDirectory: false),
                disposition: .createNew,
                probe: probe,
                hooks: probe.hooks(stagingDirectory: { _ in empty })
            ),
            .notCommitted(.stagingDirectoryInsideDestinationFolder)
        )
        XCTAssertTrue(exists(empty.path(percentEncoded: false)), "the chosen folder itself is never removed")
        XCTAssertFalse(probe.calls.contains { $0.operation == .open || $0.operation == .rmdir })
        XCTAssertEqual(
            probe.calls(at: .inspectStagingDirectory).map(\.operation),
            [.fstatat],
            "the returned directory is compared with the chosen folder by metadata before anything else"
        )
        XCTAssertEqual(try entries(in: empty), [])
    }

    /// A real cross-device pair: a destination under devfs and a staging directory on the data
    /// volume. The writer refuses before writing any byte and removes its empty directory.
    func testCrossDeviceItemReplacementDirectoryIsRefusedWithoutCopyFallback() throws {
        let fixture = try makeExportFixture()
        let staging = fixture.base.appendingPathComponent("staging", isDirectory: true)
        let destination = URL(fileURLWithPath: "/dev/plainsong-export-\(UUID().uuidString).html")
        let probe = ExportBoundaryProbe()
        let hooks = probe.hooks(
            stagingDirectory: { _ in
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                return staging
            },
            volumeCapabilities: { _ in ExportArtifactVolumeCapabilities(exclusiveRename: true, exchangeRename: true) }
        )
        XCTAssertNotEqual(try status(at: "/dev").st_dev, try status(at: fixture.directoryPath).st_dev)

        let outcome = export(to: destination, disposition: .createNew, probe: probe, hooks: hooks)

        XCTAssertEqual(outcome, .notCommitted(.stagingDirectoryOnDifferentDevice))
        XCTAssertFalse(probe.createdStaging)
        XCTAssertFalse(exists(staging.path(percentEncoded: false)))
        XCTAssertFalse(exists(destination.path(percentEncoded: false)))
    }

    /// Q1: a ubiquitous leaf or parent publishes inside `NSFileCoordinator` `.forReplacing`;
    /// a local destination does not coordinate; a coordination failure publishes nothing.
    func testUbiquitousDestinationPublishesInsideFileCoordination() throws {
        for ubiquitousURL in ["leaf", "parent", "none"] {
            let fixture = try makeExportFixture()
            let probe = ExportBoundaryProbe()
            let hooks = probe.hooks(isUbiquitous: { url in
                switch ubiquitousURL {
                case "leaf": url.path(percentEncoded: false) == fixture.destinationPath
                case "parent": url.path(percentEncoded: false) == fixture.directory.path(percentEncoded: false)
                default: false
                }
            })

            XCTAssertNotNil(requireCommitted(export(
                to: fixture.destination,
                disposition: .createNew,
                probe: probe,
                hooks: hooks
            )))

            let steps = probe.calls.map(\.step)
            if ubiquitousURL == "none" {
                XCTAssertFalse(steps.contains(.coordinate))
            } else {
                let coordinate = try XCTUnwrap(steps.firstIndex(of: .coordinate), ubiquitousURL)
                let publish = try XCTUnwrap(steps.firstIndex(of: .publish), ubiquitousURL)
                XCTAssertLessThan(coordinate, publish, "publication runs inside coordination")
                XCTAssertEqual(probe.calls(at: .coordinate).map(\.path), [fixture.destinationPath])
            }
        }

        let fixture = try makeExportFixture()
        let probe = ExportBoundaryProbe(failures: [.coordinate: EIO])
        XCTAssertEqual(
            export(
                to: fixture.destination,
                disposition: .createNew,
                probe: probe,
                hooks: probe.hooks(isUbiquitous: { _ in true })
            ),
            .notCommitted(.coordinationFailed)
        )
        XCTAssertTrue(probe.calls(at: .publish).isEmpty)
        XCTAssertFalse(exists(probe.stagingDirectoryPath))
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
    }

    func testIdentityAndTypeRacesBeforePublicationFailClosedWithoutTouchingRacer() throws {
        for race in ExportLeafRace.allCases {
            let fixture = try makeExportFixture(originalText: race == .createdRacer ? nil : "original")
            let disposition: ExportArtifactDisposition = try race == .createdRacer
                ? .createNew
                : .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
            let outside = fixture.base.appendingPathComponent("outside.html")
            try Data("outside".utf8).write(to: outside)
            let movedParent = fixture.base.appendingPathComponent("moved", isDirectory: true)
            // Races run after staging, immediately before the pre-publication re-proof.
            let probe = ExportBoundaryProbe(races: [.reproveLeaf: {
                race.perform(on: fixture, outside: outside, movedParent: movedParent)
            }])

            let outcome = export(to: fixture.destination, disposition: disposition, probe: probe)

            XCTAssertEqual(outcome, .notCommitted(race.expectedFailure), "\(race)")
            XCTAssertTrue(probe.calls(at: .publish).isEmpty, "\(race)")
            XCTAssertTrue(probe.createdStaging, "\(race)")
            XCTAssertFalse(exists(probe.stagedPath), "\(race)")
            XCTAssertFalse(exists(probe.stagingDirectoryPath), "\(race)")
            XCTAssertEqual(try text(at: outside), "outside", "\(race)")
            switch race {
            case .replacedFile, .createdRacer:
                XCTAssertEqual(try text(at: fixture.destination), "racer", "\(race)")
            case .replacedParent:
                XCTAssertEqual(try text(at: movedParent.appendingPathComponent("export.html")), "original")
            case .directory, .symbolicLink:
                break
            }
        }
    }

    /// A racer that appears between the re-proof and `renameatx_np` is never overwritten:
    /// `RENAME_EXCL` refuses it, and a swap that displaced it cannot pass postflight, so the
    /// racer is preserved at the exact reported staged path and success is impossible.
    func testRaceAtTheFinalPublishBoundaryNeverOverwritesTheRacerOrClaimsSuccess() throws {
        for replaces in [false, true] {
            let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
            let destination = fixture.destination
            let disposition: ExportArtifactDisposition = try replaces
                ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                : .createNew
            let probe = ExportBoundaryProbe(races: [.publish: {
                try? FileManager.default.removeItem(at: destination)
                try? Data("final racer".utf8).write(to: destination)
            }])

            let outcome = export("writer bytes", to: destination, disposition: disposition, probe: probe)

            XCTAssertEqual(probe.calls(at: .publish).count, 1, "no retry")
            XCTAssertTrue(probe.calls(at: .reverseSwap).isEmpty, "no reverse swap without a two-name proof")
            if replaces {
                let result = try XCTUnwrap(requireIndeterminate(outcome))
                let staged = try XCTUnwrap(probe.stagedURL)
                XCTAssertEqual(result.destinationState, .unknown)
                XCTAssertEqual(result.residue, .retained(staged, holding: .unknown))
                XCTAssertEqual(result.stagingURL, staged)
                XCTAssertEqual(result.itemReplacementDirectoryURL, probe.stagingDirectoryURL)
                XCTAssertTrue(result.residueIsInPurgeableTemporaryFolder)
                XCTAssertEqual(try text(at: staged), "final racer")
                XCTAssertEqual(try text(at: destination), "writer bytes")
            } else {
                XCTAssertEqual(outcome, .notCommitted(.destinationAlreadyExists))
                XCTAssertEqual(try text(at: destination), "final racer")
                XCTAssertFalse(exists(probe.stagingDirectoryPath))
            }
        }
    }

    /// After the re-proof passes, the chosen folder's own path component becomes a symlink to a
    /// moved copy. `RENAME_NOFOLLOW_ANY` refuses the rename, so nothing lands through the link.
    func testSymlinkedComponentAtThePublishBoundaryIsRefusedByRenameNoFollowAny() throws {
        for replaces in [false, true] {
            let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
            let disposition: ExportArtifactDisposition = try replaces
                ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                : .createNew
            let moved = fixture.base.appendingPathComponent("moved", isDirectory: true)
            let probe = ExportBoundaryProbe(races: [.publish: {
                try? FileManager.default.moveItem(at: fixture.directory, to: moved)
                try? FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: moved)
            }])

            let outcome = export("writer bytes", to: fixture.destination, disposition: disposition, probe: probe)

            XCTAssertEqual(outcome, .notCommitted(.symbolicLinkInParentPath), "replaces: \(replaces)")
            XCTAssertEqual(probe.calls(at: .publish).count, 1)
            XCTAssertFalse(exists(probe.stagingDirectoryPath))
            let expected = replaces ? ["export.html", Self.sentinelName] : [Self.sentinelName]
            XCTAssertEqual(try entries(in: moved), expected.sorted(), "replaces: \(replaces)")
            if replaces {
                XCTAssertEqual(try text(at: moved.appendingPathComponent("export.html")), "original")
            }
        }
    }
}

/// One identity or type change made to the selected leaf (or its parent) after staging.
private enum ExportLeafRace: CaseIterable {
    case replacedFile, directory, symbolicLink, createdRacer, replacedParent

    var expectedFailure: ExportArtifactFailure {
        switch self {
        case .replacedFile, .createdRacer: .destinationIdentityChanged
        case .directory: .nonRegularDestination
        case .symbolicLink: .symbolicLinkDestination
        case .replacedParent: .namespaceChanged
        }
    }

    func perform(on fixture: ExportWriterFixture, outside: URL, movedParent: URL) {
        let manager = FileManager.default
        let destination = fixture.destination
        switch self {
        case .replacedFile:
            try? manager.removeItem(at: destination)
            try? Data("racer".utf8).write(to: destination)
        case .directory:
            try? manager.removeItem(at: destination)
            try? manager.createDirectory(at: destination, withIntermediateDirectories: false)
        case .symbolicLink:
            try? manager.removeItem(at: destination)
            try? manager.createSymbolicLink(at: destination, withDestinationURL: outside)
        case .createdRacer:
            try? Data("racer".utf8).write(to: destination)
        case .replacedParent:
            try? manager.moveItem(at: fixture.directory, to: movedParent)
            try? manager.createDirectory(at: fixture.directory, withIntermediateDirectories: false)
            try? Data("original".utf8).write(to: destination)
        }
    }
}
