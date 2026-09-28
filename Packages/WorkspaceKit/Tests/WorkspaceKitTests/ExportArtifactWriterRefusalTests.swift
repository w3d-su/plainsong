import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

extension ExportArtifactWriterTests {
    func testSymbolicLinkDestinationIsRefusedForBothDispositions() throws {
        let fixture = try makeExportFixture()
        let target = fixture.base.appendingPathComponent("target.html")
        try Data("symlink target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: target)
        let linkIdentity = try identity(at: fixture.destination)

        for disposition in [ExportArtifactDisposition.createNew, .replaceConfirmed(linkIdentity)] {
            let probe = ExportBoundaryProbe()
            XCTAssertEqual(
                export(to: fixture.destination, disposition: disposition, hooks: probe.hooks()),
                .notCommitted(.symbolicLinkDestination),
                "\(disposition)"
            )
            XCTAssertFalse(probe.createdStaging)
        }
        XCTAssertEqual(
            ExportArtifactWriter.inspectDestination(at: fixture.destination, kind: .html),
            .refused(.symbolicLinkDestination)
        )
        XCTAssertEqual(try text(at: target), "symlink target")
        XCTAssertEqual(try identity(at: fixture.destination), linkIdentity)
        XCTAssertEqual(try entries(in: fixture.directory), ["export.html", Self.sentinelName].sorted())
    }

    func testSymbolicLinkInParentPathIsRefused() throws {
        let fixture = try makeExportFixture()
        let linkedParent = fixture.base.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: fixture.directory)
        let throughLink = linkedParent.appendingPathComponent("export.html", isDirectory: false)
        let probe = ExportBoundaryProbe()

        XCTAssertEqual(
            export(to: throughLink, disposition: .createNew, hooks: probe.hooks()),
            .notCommitted(.symbolicLinkInParentPath)
        )
        XCTAssertEqual(
            ExportArtifactWriter.inspectDestination(at: throughLink, kind: .html),
            .refused(.symbolicLinkInParentPath)
        )
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
    }

    func testDirectoryAndFIFODestinationsAreRefusedAsNonRegular() throws {
        let fixture = try makeExportFixture()
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        let fifo = fixture.directory.appendingPathComponent("pipe.html", isDirectory: false)
        XCTAssertEqual(fifo.path(percentEncoded: false).withCString { Darwin.mkfifo($0, 0o600) }, 0)

        for destination in [fixture.destination, fifo] {
            let existing = try identity(at: destination)
            for disposition in [ExportArtifactDisposition.createNew, .replaceConfirmed(existing)] {
                let probe = ExportBoundaryProbe()
                XCTAssertEqual(
                    export(to: destination, disposition: disposition, hooks: probe.hooks()),
                    .notCommitted(.nonRegularDestination),
                    "\(destination.lastPathComponent) \(disposition)"
                )
                XCTAssertFalse(probe.createdStaging)
            }
            XCTAssertEqual(try identity(at: destination), existing)
        }
        XCTAssertEqual(try entries(in: fixture.destination), [])
        XCTAssertEqual(
            try entries(in: fixture.directory),
            ["export.html", "pipe.html", Self.sentinelName].sorted()
        )
    }

    func testUnsupportedExtensionsAndInvalidURLsWriteNothing() throws {
        let fixture = try makeExportFixture()
        let unsupported = ["export.md", "export", ".html", "export.html.tmp", "export.pdf", "export.htm l"]
        for leaf in unsupported {
            let url = fixture.directory.appendingPathComponent(leaf, isDirectory: false)
            XCTAssertEqual(
                export(to: url, disposition: .createNew),
                .notCommitted(.unsupportedExtension),
                leaf
            )
        }
        let invalid = try [
            XCTUnwrap(URL(string: "https://example.com/export.html")),
            fixture.directory.appendingPathComponent("export.html", isDirectory: true),
            XCTUnwrap(URL(string: fixture.directory.absoluteString + "../selected/export.html")),
            XCTUnwrap(URL(string: "file:///")),
        ]
        for url in invalid {
            XCTAssertEqual(
                export(to: url, disposition: .createNew),
                .notCommitted(.invalidDestinationURL),
                url.absoluteString
            )
        }
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
        XCTAssertEqual(try entries(in: fixture.base), ["selected"])
    }

    func testDispositionMismatchesAreRefusedBeforeStaging() throws {
        let fixture = try makeExportFixture()
        let probe = ExportBoundaryProbe()
        let stale = WorkspaceFileSystemIdentity(device: 1, inode: 1)
        XCTAssertEqual(
            export(to: fixture.destination, disposition: .replaceConfirmed(stale), hooks: probe.hooks()),
            .notCommitted(.destinationMissing)
        )
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])

        try Data("existing".utf8).write(to: fixture.destination)
        let existing = try identity(at: fixture.destination)
        XCTAssertEqual(
            export(to: fixture.destination, disposition: .createNew, hooks: probe.hooks()),
            .notCommitted(.destinationAlreadyExists)
        )
        XCTAssertEqual(
            export(to: fixture.destination, disposition: .replaceConfirmed(stale), hooks: probe.hooks()),
            .notCommitted(.destinationIdentityChanged)
        )
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try text(at: fixture.destination), "existing")
        XCTAssertEqual(try identity(at: fixture.destination), existing)
    }

    func testCaseAndNormalizationAliasOfExistingLeafIsRefused() throws {
        let fixture = try makeExportFixture(leaf: "report.html", originalText: "owned spelling")
        let existing = try XCTUnwrap(fixture.originalIdentity)
        let caseAlias = fixture.directory.appendingPathComponent("Report.html", isDirectory: false)
        guard FileManager.default.fileExists(atPath: caseAlias.path(percentEncoded: false)) else {
            throw XCTSkip("Case aliases require a case-insensitive test volume")
        }
        let probe = ExportBoundaryProbe()

        for disposition in [ExportArtifactDisposition.createNew, .replaceConfirmed(existing)] {
            XCTAssertEqual(
                export(to: caseAlias, disposition: disposition, hooks: probe.hooks()),
                .notCommitted(.destinationAlias)
            )
        }
        // Foundation path helpers may decompose Unicode, so both spellings are built from
        // literal bytes and the NFC entry is created with a raw `open(2)`.
        let directoryPath = fixture.directory.path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let nfcPath = "/\(directoryPath)/caf\u{E9}.html"
        let nfdPath = "/\(directoryPath)/cafe\u{301}.html"
        let descriptor = nfcPath.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        Darwin.close(descriptor)
        if nfdPath.withCString({ Darwin.access($0, F_OK) }) == 0 {
            let nfcIdentity = try identity(at: WorkspaceLiteralFileURL.fileURL(path: nfcPath, isDirectory: false))
            let nfdURL = WorkspaceLiteralFileURL.fileURL(path: nfdPath, isDirectory: false)
            XCTAssertEqual(
                export(to: nfdURL, disposition: .replaceConfirmed(nfcIdentity), hooks: probe.hooks()),
                .notCommitted(.destinationAlias)
            )
            XCTAssertEqual(
                try identity(at: WorkspaceLiteralFileURL.fileURL(path: nfcPath, isDirectory: false)),
                nfcIdentity
            )
        }
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try text(at: fixture.destination), "owned spelling")
        XCTAssertEqual(try identity(at: fixture.destination), existing)
    }

    func testMissingParentAuthorityFailsBeforeAnyWrite() throws {
        let fixture = try makeExportFixture()
        let missingParent = fixture.base.appendingPathComponent("absent", isDirectory: true)
            .appendingPathComponent("export.html", isDirectory: false)
        XCTAssertEqual(
            export(to: missingParent, disposition: .createNew),
            .notCommitted(.parentAuthorityUnavailable)
        )
        let directoryPath = fixture.directory.path(percentEncoded: false)
        XCTAssertEqual(Darwin.chmod(directoryPath, 0o300), 0)
        defer { _ = Darwin.chmod(directoryPath, 0o700) }
        let probe = ExportBoundaryProbe()

        XCTAssertEqual(
            export(to: fixture.destination, disposition: .createNew, hooks: probe.hooks()),
            .notCommitted(.parentAuthorityUnavailable)
        )
        XCTAssertEqual(
            ExportArtifactWriter.inspectDestination(at: fixture.destination, kind: .html),
            .refused(.parentAuthorityUnavailable)
        )
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(Darwin.chmod(directoryPath, 0o700), 0)
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
        XCTAssertEqual(try entries(in: fixture.base), ["selected"])
    }

    func testDeniedStagingCreateIsNotCommittedWithoutAnyFallbackWrite() throws {
        struct Denial {
            let name: String
            let apply: (String) -> Int32
            let undo: (String) -> Int32
            let code: Int32
        }
        let denials = [
            Denial(
                name: "mode 0500 (EACCES)",
                apply: { Darwin.chmod($0, 0o500) },
                undo: { Darwin.chmod($0, 0o700) },
                code: EACCES
            ),
            Denial(
                name: "UF_IMMUTABLE (EPERM)",
                apply: { Darwin.chflags($0, UInt32(UF_IMMUTABLE)) },
                undo: { Darwin.chflags($0, 0) },
                code: EPERM
            ),
        ]
        for denial in denials {
            for replaces in [false, true] {
                let fixture = try makeExportFixture(originalText: replaces ? "original" : nil)
                let disposition: ExportArtifactDisposition = try replaces
                    ? .replaceConfirmed(XCTUnwrap(fixture.originalIdentity))
                    : .createNew
                let directoryPath = fixture.directory.path(percentEncoded: false)
                let before = try entries(in: fixture.directory)
                XCTAssertEqual(denial.apply(directoryPath), 0, denial.name)

                let outcome = export(to: fixture.destination, disposition: disposition)

                XCTAssertEqual(denial.undo(directoryPath), 0, denial.name)
                XCTAssertEqual(
                    outcome,
                    .notCommitted(.stagingNotPermitted(code: denial.code)),
                    "\(denial.name) replaces: \(replaces)"
                )
                XCTAssertEqual(try entries(in: fixture.directory), before, denial.name)
                XCTAssertEqual(try entries(in: fixture.base), ["selected"], denial.name)
                if replaces {
                    XCTAssertEqual(try text(at: fixture.destination), "original")
                    XCTAssertEqual(try identity(at: fixture.destination), fixture.originalIdentity)
                }
            }
        }
    }

    func testUnsupportedVolumeSemanticsFailClosedBeforeStaging() throws {
        let fixture = try makeExportFixture()
        let noExclusive = ExportArtifactVolumeCapabilities(exclusiveRename: false, exchangeRename: true)
        let noExchange = ExportArtifactVolumeCapabilities(exclusiveRename: true, exchangeRename: false)
        let probe = ExportBoundaryProbe()

        XCTAssertEqual(
            export(
                to: fixture.destination,
                disposition: .createNew,
                hooks: probe.hooks(volumeCapabilities: { _ in noExclusive })
            ),
            .notCommitted(.unsupportedVolumeSemantics)
        )
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
        try Data("original".utf8).write(to: fixture.destination)
        let existing = try identity(at: fixture.destination)
        for capabilities in [noExclusive, noExchange] {
            XCTAssertEqual(
                export(
                    to: fixture.destination,
                    disposition: .replaceConfirmed(existing),
                    hooks: probe.hooks(volumeCapabilities: { _ in capabilities })
                ),
                .notCommitted(.unsupportedVolumeSemantics)
            )
        }
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try text(at: fixture.destination), "original")
        XCTAssertEqual(try identity(at: fixture.destination), existing)
    }

    func testProbedVolumeCapabilitiesReportExclusiveAndExchangeRenameOnTestVolume() throws {
        let fixture = try makeExportFixture()
        let descriptor = fixture.directory.path(percentEncoded: false).withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        let devfs = "/dev".withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        defer { if devfs >= 0 { Darwin.close(devfs) } }

        XCTAssertEqual(
            ExportArtifactWriter.probeVolumeCapabilities(descriptor),
            ExportArtifactVolumeCapabilities(exclusiveRename: true, exchangeRename: true),
            "the APFS test volume reports both rename semantics"
        )
        if devfs >= 0 {
            XCTAssertEqual(
                ExportArtifactWriter.probeVolumeCapabilities(devfs),
                ExportArtifactVolumeCapabilities(exclusiveRename: false, exchangeRename: false),
                "devfs does not report either semantic and is treated as unsupported"
            )
        }
    }

    func testOwnershipRefusalWritesNothingAndReceivesTheWritersInspection() throws {
        let fixture = try makeExportFixture(originalText: "owned elsewhere")
        let existing = try XCTUnwrap(fixture.originalIdentity)
        var received: [WorkspaceNoFollowFileTargetInspection] = []
        let probe = ExportBoundaryProbe()

        let outcome = export(
            to: fixture.destination,
            disposition: .replaceConfirmed(existing),
            hooks: probe.hooks()
        ) { inspection in
            received.append(inspection)
            return .refused
        }

        XCTAssertEqual(outcome, .notCommitted(.ownedDestination))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.state, .regular(existing))
        XCTAssertEqual(
            received.first?.canonicalLocation.fileURL.path(percentEncoded: false),
            fixture.destination.path(percentEncoded: false)
        )
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try text(at: fixture.destination), "owned elsewhere")
        XCTAssertEqual(try identity(at: fixture.destination), existing)
    }
}
