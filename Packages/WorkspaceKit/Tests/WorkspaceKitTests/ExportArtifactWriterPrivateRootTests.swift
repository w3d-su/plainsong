import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

extension ExportArtifactWriterTests {
    func testPrivateRootGetattrlistFailureRefusesRuleBWithoutPublication() throws {
        let fixture = try makeExportFixture()
        let sandbox = try makeFakeSandbox(fixture)
        let probe = ExportBoundaryProbe(failures: [.canonicalizePrivateRoot: EIO])
        let destination = sandbox.home.appendingPathComponent("export.html")
        let outcome = export(to: destination, disposition: .createNew, probe: probe,
                             hooks: probe.hooks(stagingDirectory: sandbox.provider),
                             appPrivateRoot: sandbox.privateRoot)
        XCTAssertEqual(outcome, .notCommitted(.stagingDirectoryInsideDestinationFolder))
        XCTAssertEqual(probe.calls(at: .inspectPrivateRoot).map(\.operation), [.fstatat])
        XCTAssertEqual(probe.calls(at: .canonicalizePrivateRoot).map(\.operation), [.fullPath])
        XCTAssertFalse(probe.createdStaging)
        XCTAssertFalse(exists(destination.path(percentEncoded: false)))
        XCTAssertEqual(try entries(in: sandbox.temporaryItems), [])
    }

    func testNonDirectoryPrivateRootRefusesRuleBBeforeGetattrlist() throws {
        let fixture = try makeExportFixture()
        let sandbox = try makeFakeSandbox(fixture)
        let fileRoot = sandbox.home.appendingPathComponent("file-root")
        try Data().write(to: fileRoot)
        let probe = ExportBoundaryProbe()
        let outcome = export(to: sandbox.home.appendingPathComponent("export.html"), disposition: .createNew,
                             probe: probe, hooks: probe.hooks(stagingDirectory: sandbox.provider),
                             appPrivateRoot: fileRoot)
        XCTAssertEqual(outcome, .notCommitted(.stagingDirectoryInsideDestinationFolder))
        XCTAssertTrue(probe.calls(at: .canonicalizePrivateRoot).isEmpty)
        XCTAssertFalse(probe.createdStaging)
        XCTAssertEqual(try entries(in: sandbox.temporaryItems), [])
    }

    /// A different directory, or a final-component symlink, between stat and getattrlist is not
    /// the private root proven before staging. The same production type/identity guard refuses.
    func testPrivateRootTypeOrIdentityChangeBeforeGetattrlistRefusesRuleB() throws {
        for replaceWithSymlink in [false, true] {
            let fixture = try makeExportFixture()
            let sandbox = try makeFakeSandbox(fixture)
            let moved = sandbox.privateRoot.deletingLastPathComponent().appendingPathComponent("Data-moved")
            let probe = ExportBoundaryProbe(races: [.canonicalizePrivateRoot: {
                try? FileManager.default.moveItem(at: sandbox.privateRoot, to: moved)
                if replaceWithSymlink {
                    try? FileManager.default.createSymbolicLink(at: sandbox.privateRoot, withDestinationURL: moved)
                } else {
                    try? FileManager.default.createDirectory(
                        at: sandbox.temporaryItems,
                        withIntermediateDirectories: true
                    )
                }
            }])
            let outcome = export(to: sandbox.home.appendingPathComponent("export.html"), disposition: .createNew,
                                 probe: probe, hooks: probe.hooks(stagingDirectory: sandbox.provider),
                                 appPrivateRoot: sandbox.privateRoot)
            let report = try XCTUnwrap(requireIndeterminate(outcome))
            XCTAssertEqual(report.destinationState, .provenUnchanged)
            XCTAssertEqual(report.unprovenDirectoryURLs.map { $0.path(percentEncoded: false) },
                           [sandbox.privateRoot.path(percentEncoded: false)])
            XCTAssertNil(report.itemReplacementDirectoryURL)
            XCTAssertEqual(probe.calls(at: .canonicalizePrivateRoot).map(\.operation), [.fullPath])
            XCTAssertFalse(probe.createdStaging)
            XCTAssertTrue(probe.calls(at: .publish).isEmpty)
            XCTAssertFalse(exists(sandbox.home.appendingPathComponent("export.html").path(percentEncoded: false)))
        }
    }

    func testPrivateRootFirmlinkSpellingUsesKernelCanonicalContainment() throws {
        let fixture = try makeExportFixture()
        let sandbox = try makeFakeSandbox(fixture)
        let alias = URL(fileURLWithPath: "/System/Volumes/Data\(sandbox.privateRoot.path(percentEncoded: false))")
        guard FileManager.default.fileExists(atPath: alias.path(percentEncoded: false)) else {
            throw XCTSkip("No firmlink spelling on this test volume")
        }
        let probe = ExportBoundaryProbe()
        let destination = sandbox.home.appendingPathComponent("export.html")
        let outcome = export(to: destination, disposition: .createNew, probe: probe,
                             hooks: probe.hooks(stagingDirectory: sandbox.provider), appPrivateRoot: alias)
        XCTAssertNotNil(requireCommitted(outcome))
        XCTAssertTrue(probe.createdStaging)
        XCTAssertEqual(try text(at: destination), "<!doctype html><title>Export</title>")
        XCTAssertEqual(try entries(in: sandbox.temporaryItems), [])
    }
}
