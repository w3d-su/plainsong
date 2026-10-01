import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

extension ExportArtifactWriterTests {
    func testSymbolicLinkLeafIsRefusedForBothDispositions() throws {
        let fixture = try makeExportFixture()
        let target = fixture.base.appendingPathComponent("target.html")
        try Data("symlink target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: target)
        let linkIdentity = try identity(at: fixture.destination)

        for disposition in [ExportArtifactDisposition.createNew, .replaceConfirmed(linkIdentity)] {
            let probe = ExportBoundaryProbe()
            XCTAssertEqual(
                export(to: fixture.destination, disposition: disposition, probe: probe),
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

    /// `AT_SYMLINK_NOFOLLOW_ANY` refuses a symlink anywhere in the selected path: the final
    /// parent component and an intermediate component alike.
    func testSymbolicLinkPathComponentIsRefused() throws {
        let fixture = try makeExportFixture()
        let linkedParent = fixture.base.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: fixture.directory)
        let linkedBase = fixture.base.appendingPathComponent("linked-base", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedBase, withDestinationURL: fixture.base)
        let throughFinalComponent = linkedParent.appendingPathComponent("export.html", isDirectory: false)
        let throughIntermediate = linkedBase.appendingPathComponent("selected/export.html", isDirectory: false)

        for url in [throughFinalComponent, throughIntermediate] {
            let probe = ExportBoundaryProbe()
            XCTAssertEqual(
                export(to: url, disposition: .createNew, probe: probe),
                .notCommitted(.symbolicLinkInParentPath),
                url.path(percentEncoded: false)
            )
            XCTAssertEqual(
                ExportArtifactWriter.inspectDestination(at: url, kind: .html),
                .refused(.symbolicLinkInParentPath)
            )
            XCTAssertFalse(probe.createdStaging)
        }
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
    }

    func testDirectoryAndFIFOLeavesAreRefusedAsNonRegular() throws {
        let fixture = try makeExportFixture()
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        let fifo = fixture.directory.appendingPathComponent("pipe.html", isDirectory: false)
        XCTAssertEqual(fifo.path(percentEncoded: false).withCString { Darwin.mkfifo($0, 0o600) }, 0)

        // Device nodes cannot be created unprivileged; the FIFO exercises the same refusal.
        for destination in [fixture.destination, fifo] {
            let existing = try identity(at: destination)
            for disposition in [ExportArtifactDisposition.createNew, .replaceConfirmed(existing)] {
                let probe = ExportBoundaryProbe()
                XCTAssertEqual(
                    export(to: destination, disposition: disposition, probe: probe),
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
            XCTAssertEqual(export(to: url, disposition: .createNew), .notCommitted(.unsupportedExtension), leaf)
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
            export(to: fixture.destination, disposition: .replaceConfirmed(stale), probe: probe),
            .notCommitted(.destinationMissing)
        )
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])

        try Data("existing".utf8).write(to: fixture.destination)
        let existing = try identity(at: fixture.destination)
        XCTAssertEqual(
            export(to: fixture.destination, disposition: .createNew, probe: probe),
            .notCommitted(.destinationAlreadyExists)
        )
        XCTAssertEqual(
            export(to: fixture.destination, disposition: .replaceConfirmed(stale), probe: probe),
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
                export(to: caseAlias, disposition: disposition, probe: probe),
                .notCommitted(.destinationAlias)
            )
        }
        XCTAssertEqual(
            ExportArtifactWriter.inspectDestination(at: caseAlias, kind: .html),
            .refused(.destinationAlias)
        )
        XCTAssertEqual(ExportArtifactWriter.inspectLeaf(at: caseAlias), .failure(.destinationAlias))
        // Foundation path helpers may decompose Unicode, so both spellings are built from
        // literal bytes and the NFC entry is created with a raw `open(2)`.
        let nfcPath = "\(fixture.directoryPath)/caf\u{E9}.html"
        let nfdPath = "\(fixture.directoryPath)/cafe\u{301}.html"
        let descriptor = nfcPath.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        Darwin.close(descriptor)
        if nfdPath.withCString({ Darwin.access($0, F_OK) }) == 0 {
            let nfcURL = WorkspaceLiteralFileURL.fileURL(path: nfcPath, isDirectory: false)
            let nfcIdentity = try identity(at: nfcURL)
            let nfdURL = WorkspaceLiteralFileURL.fileURL(path: nfdPath, isDirectory: false)
            XCTAssertEqual(
                export(to: nfdURL, disposition: .replaceConfirmed(nfcIdentity), probe: probe),
                .notCommitted(.destinationAlias)
            )
            XCTAssertEqual(try identity(at: nfcURL), nfcIdentity)
        }
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try text(at: fixture.destination), "owned spelling")
        XCTAssertEqual(try identity(at: fixture.destination), existing)
    }

    /// A new leaf has no `F_GETPATH`, so the parent's `getattrlist(ATTR_CMN_FULLPATH)` spelling
    /// must equal the selected one: a firmlink, case, or normalization spelling of the chosen
    /// folder fails closed before ownership, and the folder is still never opened.
    func testFirmlinkCaseOrNormalizationSpellingOfTheParentIsRefused() throws {
        let fixture = try makeExportFixture()
        let nfcFolder = "\(fixture.base.path(percentEncoded: false))caf\u{E9}"
        XCTAssertEqual(nfcFolder.withCString { Darwin.mkdir($0, 0o700) }, 0)
        var parents = ["/System/Volumes/Data\(fixture.directoryPath)"]
        parents.append(((fixture.directoryPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("SELECTED"))
        parents.append("\(fixture.base.path(percentEncoded: false))cafe\u{301}")
        let reachable = parents.filter { exists($0) }
        guard !reachable.isEmpty else {
            throw XCTSkip("No firmlink, case, or normalization alias spelling reaches the test folder")
        }
        for parent in reachable {
            let url = WorkspaceLiteralFileURL.fileURL(path: "\(parent)/export.html", isDirectory: false)
            let probe = ExportBoundaryProbe()

            XCTAssertEqual(
                export(to: url, disposition: .createNew, probe: probe),
                .notCommitted(.destinationAlias),
                parent
            )

            XCTAssertEqual(ExportArtifactWriter.inspectLeaf(at: url), .failure(.destinationAlias), parent)
            XCTAssertEqual(
                ExportArtifactWriter.inspectDestination(at: url, kind: .html),
                .refused(.destinationAlias),
                parent
            )
            XCTAssertFalse(probe.createdStaging, parent)
            XCTAssertFalse(probe.calls.contains { $0.operation == .open }, "the parent is never opened: \(parent)")
            XCTAssertTrue(probe.calls.contains { $0.path == parent && $0.operation == .fullPath }, parent)
        }
        // An existing leaf reached through the firmlink fails by its F_GETPATH spelling.
        try Data("original".utf8).write(to: fixture.destination)
        let existing = try identity(at: fixture.destination)
        if exists(reachable.first) {
            let url = WorkspaceLiteralFileURL.fileURL(path: "\(reachable[0])/export.html", isDirectory: false)
            XCTAssertEqual(export(to: url, disposition: .replaceConfirmed(existing)), .notCommitted(.destinationAlias))
        }
        XCTAssertEqual(try text(at: fixture.destination), "original")
        XCTAssertEqual(try entries(in: fixture.directory), ["export.html", Self.sentinelName].sorted())
    }

    func testMissingOrUnsearchableParentFailsBeforeAnyWrite() throws {
        let fixture = try makeExportFixture()
        let missingParent = fixture.base.appendingPathComponent("absent/export.html", isDirectory: false)
        let fileParent = fixture.sentinel.appendingPathComponent("export.html", isDirectory: false)
        for url in [missingParent, fileParent] {
            XCTAssertEqual(
                export(to: url, disposition: .createNew),
                .notCommitted(.parentAuthorityUnavailable),
                url.path(percentEncoded: false)
            )
        }
        // Mode 0600 removes search permission, so even the leaf's metadata is unreadable.
        XCTAssertEqual(Darwin.chmod(fixture.directoryPath, 0o600), 0)
        defer { _ = Darwin.chmod(fixture.directoryPath, 0o700) }
        let probe = ExportBoundaryProbe()

        XCTAssertEqual(
            export(to: fixture.destination, disposition: .createNew, probe: probe),
            .notCommitted(.parentAuthorityUnavailable)
        )
        XCTAssertEqual(
            ExportArtifactWriter.inspectDestination(at: fixture.destination, kind: .html),
            .refused(.parentAuthorityUnavailable)
        )
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(Darwin.chmod(fixture.directoryPath, 0o700), 0)
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
        XCTAssertEqual(try entries(in: fixture.base), ["selected"])
    }

    func testUnsupportedVolumeCapabilitiesFailClosedBeforeStaging() throws {
        let fixture = try makeExportFixture()
        try assertUnsupportedCapabilitiesRefuse(
            fixture,
            disposition: .createNew,
            queriedPath: fixture.directory.path(percentEncoded: false),
            "a new leaf reads the parent URL's volume keys"
        )
        try Data("original".utf8).write(to: fixture.destination)
        let existing = try identity(at: fixture.destination)
        try assertUnsupportedCapabilitiesRefuse(
            fixture,
            disposition: .replaceConfirmed(existing),
            queriedPath: fixture.destinationPath,
            "an overwrite reads the existing leaf's volume keys"
        )
        XCTAssertEqual(try text(at: fixture.destination), "original")
        XCTAssertEqual(try identity(at: fixture.destination), existing)
    }

    private func assertUnsupportedCapabilitiesRefuse(
        _ fixture: ExportWriterFixture,
        disposition: ExportArtifactDisposition,
        queriedPath: String,
        _ message: String
    ) throws {
        let unsupported: [ExportArtifactVolumeCapabilities?] = [
            ExportArtifactVolumeCapabilities(exclusiveRename: false, exchangeRename: true),
            ExportArtifactVolumeCapabilities(exclusiveRename: true, exchangeRename: false),
            nil,
        ]
        let queried = URLRecorder()
        for capabilities in unsupported {
            let probe = ExportBoundaryProbe()
            let hooks = probe.hooks(volumeCapabilities: { url in
                queried.append(url)
                return capabilities
            })
            XCTAssertEqual(
                export(to: fixture.destination, disposition: disposition, probe: probe, hooks: hooks),
                .notCommitted(.unsupportedVolumeSemantics),
                message
            )
            XCTAssertEqual(
                ExportArtifactWriter.inspectDestination(at: fixture.destination, kind: .html, hooks: hooks),
                .refused(.unsupportedVolumeSemantics),
                message
            )
            XCTAssertFalse(probe.createdStaging, message)
        }
        XCTAssertFalse(queried.values.isEmpty, message)
        XCTAssertTrue(queried.values.allSatisfy { $0.path(percentEncoded: false) == queriedPath }, message)
    }

    func testRealVolumeKeysReportBothRenameSemanticsOnTheTestVolume() throws {
        let fixture = try makeExportFixture()
        let hooks = ExportArtifactWriterHooks.production
        XCTAssertEqual(
            hooks.capabilities(at: fixture.directory),
            ExportArtifactVolumeCapabilities(exclusiveRename: true, exchangeRename: true),
            "the APFS test volume advertises both rename semantics"
        )
        XCTAssertEqual(
            hooks.capabilities(at: URL(fileURLWithPath: "/dev", isDirectory: true)),
            ExportArtifactVolumeCapabilities(exclusiveRename: false, exchangeRename: false),
            "devfs advertises neither and is treated as unsupported"
        )
    }

    func testOwnershipRefusalWritesNothingAndReceivesTheLeafInspection() throws {
        let fixture = try makeExportFixture(originalText: "owned elsewhere")
        let existing = try XCTUnwrap(fixture.originalIdentity)
        var received: [ExportArtifactLeafInspection] = []
        let probe = ExportBoundaryProbe()

        let outcome = export(to: fixture.destination, disposition: .replaceConfirmed(existing), probe: probe) {
            received.append($0)
            return .refused
        }

        XCTAssertEqual(outcome, .notCommitted(.ownedDestination))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.state, .regular(existing))
        XCTAssertEqual(received.first, try ExportArtifactWriter.inspectLeaf(at: fixture.destination).get())
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try text(at: fixture.destination), "owned elsewhere")
        XCTAssertEqual(try identity(at: fixture.destination), existing)
    }
}
