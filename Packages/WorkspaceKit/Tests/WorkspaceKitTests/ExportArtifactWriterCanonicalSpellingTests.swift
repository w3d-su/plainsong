import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

/// The `getattrlist` canonical-spelling observations: one combined reply per entry, strict
/// parsing, and a distinct fault-injection boundary for each caller.
extension ExportArtifactWriterTests {
    func testParentSpellingObservationFailureAtPreflightWritesNothing() throws {
        let fixture = try makeExportFixture()
        for (code, expected) in [
            (EIO, ExportArtifactFailure.parentAuthorityUnavailable),
            (ELOOP, .symbolicLinkInParentPath),
        ] {
            let probe = ExportBoundaryProbe(failures: [.canonicalizeParent: code])

            let outcome = export(to: fixture.destination, disposition: .createNew, probe: probe)

            XCTAssertEqual(outcome, .notCommitted(expected), "errno \(code)")
            XCTAssertEqual(
                ExportArtifactWriter.inspectDestination(
                    at: fixture.destination,
                    kind: .html,
                    hooks: ExportBoundaryProbe(failures: [.canonicalizeParent: code]).hooks()
                ),
                .refused(expected),
                "errno \(code)"
            )
            XCTAssertEqual(probe.calls(at: .canonicalizeParent).count, 1)
            XCTAssertFalse(probe.createdStaging)
            XCTAssertNil(probe.stagingDirectoryPath)
        }
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
    }

    /// The same observation fails only at the pre-publication re-proof: nothing is published,
    /// and the writer's staged file and directory are removed.
    func testParentSpellingObservationFailureAtTheReproofPublishesNothing() throws {
        let fixture = try makeExportFixture()
        let probe = ExportBoundaryProbe(armedFailures: [.canonicalizeParent: EIO], armingStep: .reproveLeaf)

        let outcome = export(to: fixture.destination, disposition: .createNew, probe: probe)

        XCTAssertEqual(outcome, .notCommitted(.parentAuthorityUnavailable))
        XCTAssertEqual(probe.calls(at: .canonicalizeParent).count, 2, "preflight passed; the re-proof failed")
        XCTAssertTrue(probe.createdStaging)
        XCTAssertTrue(probe.calls(at: .publish).isEmpty)
        XCTAssertFalse(exists(probe.stagedPath))
        XCTAssertFalse(exists(probe.stagingDirectoryPath))
        XCTAssertEqual(try entries(in: fixture.directory), [Self.sentinelName])
    }

    /// A private root whose observation fails leaves only rule (a): staging below it, inside the
    /// chosen folder, is refused and removed.
    func testPrivateRootObservationFailureLeavesOnlyRuleA() throws {
        let fixture = try makeExportFixture()
        let sandbox = try makeFakeSandbox(fixture)
        let before = try entries(in: sandbox.home)
        let probe = ExportBoundaryProbe(failures: [.canonicalizePrivateRoot: EIO])

        let outcome = export(
            to: sandbox.home.appendingPathComponent("export.html", isDirectory: false),
            disposition: .createNew,
            probe: probe,
            hooks: probe.hooks(stagingDirectory: sandbox.provider),
            appPrivateRoot: sandbox.privateRoot
        )

        XCTAssertEqual(outcome, .notCommitted(.stagingDirectoryInsideDestinationFolder))
        XCTAssertEqual(probe.calls(at: .canonicalizePrivateRoot).count, 1)
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try entries(in: sandbox.temporaryItems), [])
        XCTAssertEqual(try entries(in: sandbox.home), before)
    }

    /// Between the parent's `fstatat` and its `getattrlist`, the chosen folder is replaced by a
    /// symlink to its moved self. `FSOPT_NOFOLLOW_ANY` reports the link's own (equal) spelling,
    /// so only the identity and type from the same observation refuse it.
    func testSymlinkSwappedInBeforeTheParentSpellingObservationIsRefused() throws {
        let fixture = try makeExportFixture()
        let moved = fixture.base.appendingPathComponent("moved", isDirectory: true)
        let probe = ExportBoundaryProbe(races: [.canonicalizeParent: {
            try? FileManager.default.moveItem(at: fixture.directory, to: moved)
            try? FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: moved)
        }])

        let outcome = export(to: fixture.destination, disposition: .createNew, probe: probe)

        XCTAssertEqual(outcome, .notCommitted(.namespaceChanged))
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try entries(in: moved), [Self.sentinelName])
    }

    func testPathAttributeReplyParsingIsStrict() {
        let path = Array("/Users/example/folder".utf8)
        XCTAssertEqual(
            parsedReply(path: path)?.path,
            path,
            "a well-formed reply parses, even at an unaligned address"
        )
        XCTAssertEqual(parsedReply(path: path)?.identity, WorkspaceFileSystemIdentity(device: 7, inode: 0x1_0000_0001))
        XCTAssertEqual(parsedReply(path: path)?.isDirectory, true)
        XCTAssertEqual(parsedReply(path: path, type: UInt32(VLNK.rawValue))?.isDirectory, false)
        let malformed: [(String, ExportPathReply?)] = [
            ("truncated before the header", nil),
            ("returned length beyond the buffer", ExportPathReply(path: path, returnedLengthDelta: 64)),
            ("returned length inside the header", ExportPathReply(path: path, returnedLengthOverride: 20)),
            ("data offset into the header", ExportPathReply(path: path, dataOffsetOverride: 0)),
            ("data beyond the returned length", ExportPathReply(path: path, dataLengthDelta: 4)),
            ("missing NUL", ExportPathReply(path: path, terminator: [])),
            ("interior NUL", ExportPathReply(path: Array("/a\u{0}b".utf8))),
            ("relative path", ExportPathReply(path: Array("Users/example".utf8))),
            ("empty path", ExportPathReply(path: [])),
        ]
        for (label, reply) in malformed {
            let bytes = reply?.bytes ?? Array(repeating: 0, count: 12)
            XCTAssertNil(parse(bytes, unaligned: false), label)
            XCTAssertNil(parse(bytes, unaligned: true), label)
        }
    }

    /// The sign bit in Darwin's `dev_t` is part of the device ID, including on real devfs
    /// volumes. Both metadata sources must preserve all 32 bits with the same zero extension.
    func testDeviceIdentityPreservesSignedDeviceBitsAcrossStatAndPathAttributes() throws {
        let path = Array("/dev".utf8)
        let devices: [(dev_t, UInt64)] = [
            (0, 0),
            (7, 7),
            (.max, 0x7FFF_FFFF),
            (.min, 0x8000_0000),
            (-1, 0xFFFF_FFFF),
        ]
        for (device, expected) in devices {
            var status = stat()
            status.st_dev = device
            status.st_ino = 0x1_0000_0001
            let identity = WorkspaceFileSystemIdentity(exportStatus: status)
            XCTAssertEqual(identity, WorkspaceFileSystemIdentity(device: expected, inode: 0x1_0000_0001))
            let bytes = ExportPathReply(path: path, device: device).bytes
            for unaligned in [false, true] {
                let attributes = try XCTUnwrap(parse(bytes, unaligned: unaligned))
                XCTAssertEqual(attributes.identity, identity)
                XCTAssertEqual(attributes.path, path)
                XCTAssertTrue(attributes.isDirectory)
            }
        }
    }

    private func parsedReply(
        path: [UInt8],
        type: UInt32 = UInt32(VDIR.rawValue)
    ) -> ExportArtifactPathAttributes? {
        let bytes = ExportPathReply(path: path, type: type).bytes
        let aligned = parse(bytes, unaligned: false)
        XCTAssertEqual(aligned, parse(bytes, unaligned: true))
        return aligned
    }

    private func parse(_ bytes: [UInt8], unaligned: Bool) -> ExportArtifactPathAttributes? {
        let shifted = (unaligned ? [0] : []) + bytes
        return shifted.withUnsafeBytes { raw in
            ExportArtifactPathAttributes.parse(UnsafeRawBufferPointer(rebasing: raw[(unaligned ? 1 : 0)...]))
        }
    }
}

/// A synthesized `getattrlist` reply for DEVID | OBJTYPE | FILEID | FULLPATH, with knobs that
/// break one validation at a time.
struct ExportPathReply {
    var path: [UInt8]
    var device: Int32 = 7
    var type = UInt32(VDIR.rawValue)
    var returnedLengthDelta = 0
    var returnedLengthOverride: Int?
    var dataOffsetOverride: Int32?
    var dataLengthDelta = 0
    var terminator: [UInt8] = [0]

    var bytes: [UInt8] {
        let data = path + terminator
        let header = 28
        var reply: [UInt8] = []
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.littleEndian) { reply.append(contentsOf: $0) }
        }
        let returnedLength = returnedLengthOverride ?? (header + data.count + returnedLengthDelta)
        append(UInt32(returnedLength))
        append(device)
        append(type)
        append(UInt64(0x1_0000_0001))
        append(dataOffsetOverride ?? Int32(header - 20))
        append(UInt32(data.count + dataLengthDelta))
        reply.append(contentsOf: data)
        return reply
    }
}
