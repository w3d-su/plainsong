import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

extension ExportArtifactWriterTests {
    /// The shared ancestors are never operation-owned. Refusing Foundation's nested NSIRD
    /// directory cannot claim a clean non-commit when either ancestor was created by the call.
    func testFoundationScaffoldingIsReportedAfterTheReturnedDirectoryIsRemoved() throws {
        for preexistingDepth in 0 ... 2 {
            let fixture = try makeExportFixture()
            let temporary = fixture.directory.appendingPathComponent(".TemporaryItems", isDirectory: true)
            let userFolder = temporary.appendingPathComponent("folders.\(getuid())", isDirectory: true)
            let directory = userFolder.appendingPathComponent("NSIRD_test", isDirectory: true)
            if preexistingDepth > 0 {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            }
            if preexistingDepth > 1 {
                try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: false)
            }
            let probe = ExportBoundaryProbe()
            let outcome = export(to: fixture.destination, disposition: .createNew, probe: probe,
                                 hooks: probe.hooks(stagingDirectory: { _ in
                                     try FileManager.default.createDirectory(
                                         at: directory,
                                         withIntermediateDirectories: true
                                     )
                                     return directory
                                 }))
            if preexistingDepth == 2 {
                XCTAssertEqual(outcome, .notCommitted(.stagingDirectoryInsideDestinationFolder))
            } else {
                let report = try XCTUnwrap(requireIndeterminate(outcome))
                XCTAssertEqual(report.destinationState, .provenUnchanged)
                XCTAssertEqual(report.residue, .none)
                XCTAssertNil(report.itemReplacementDirectoryURL)
                XCTAssertNil(report.stagingURL)
                let expected = preexistingDepth == 0 ? [temporary, userFolder] : [userFolder]
                XCTAssertEqual(report.unprovenDirectoryURLs.map { $0.path(percentEncoded: false) },
                               expected.map { $0.path(percentEncoded: false) })
            }
            XCTAssertFalse(exists(directory.path(percentEncoded: false)))
            XCTAssertTrue(exists(userFolder.path(percentEncoded: false)))
            XCTAssertFalse(exists(fixture.destinationPath))
            XCTAssertEqual(probe.calls.filter { $0.operation == .rmdir }.map(\.path),
                           [WorkspaceRootContainment.normalizedDirectoryPath(directory.path(percentEncoded: false))])
            XCTAssertFalse(probe.calls.contains { $0.operation == .open }, "refusal opens nothing")
        }
    }

    func testFoundationScaffoldingIsReportedEvenWhenTheProviderThrows() throws {
        let fixture = try makeExportFixture()
        let temporary = fixture.directory.appendingPathComponent(".TemporaryItems", isDirectory: true)
        let userFolder = temporary.appendingPathComponent("folders.\(getuid())", isDirectory: true)
        let probe = ExportBoundaryProbe()
        let outcome = export(to: fixture.destination, disposition: .createNew, probe: probe,
                             hooks: probe.hooks(stagingDirectory: { _ in
                                 try FileManager.default.createDirectory(
                                     at: userFolder,
                                     withIntermediateDirectories: true
                                 )
                                 throw CocoaError(.fileWriteNoPermission)
                             }))
        let report = try XCTUnwrap(requireIndeterminate(outcome))
        XCTAssertEqual(report.unprovenDirectoryURLs.map { $0.path(percentEncoded: false) },
                       [temporary, userFolder].map { $0.path(percentEncoded: false) })
        XCTAssertNil(report.itemReplacementDirectoryURL)
        XCTAssertEqual(report.destinationState, .provenUnchanged)
        XCTAssertTrue(probe.calls.filter { $0.operation == .rmdir }.isEmpty)
        XCTAssertFalse(exists(fixture.destinationPath))
    }

    func testUnobservableFoundationScaffoldingBelowTheReturnedPathIsReported() throws {
        let fixture = try makeExportFixture()
        let temporary = fixture.directory.appendingPathComponent(".TemporaryItems", isDirectory: true)
        let userFolder = temporary.appendingPathComponent("folders.\(getuid())", isDirectory: true)
        let directory = userFolder.appendingPathComponent("NSIRD_test", isDirectory: true)
        let probe = ExportBoundaryProbe(armedFailures: [.inspectFoundationScaffolding: EACCES],
                                        armingStep: .inspectStagingDirectory)
        let outcome = export(to: fixture.destination, disposition: .createNew, probe: probe,
                             hooks: probe.hooks(stagingDirectory: { _ in
                                 try FileManager.default.createDirectory(
                                     at: directory,
                                     withIntermediateDirectories: true
                                 )
                                 return directory
                             }))
        let report = try XCTUnwrap(requireIndeterminate(outcome))
        XCTAssertEqual(report.unprovenDirectoryURLs.map { $0.path(percentEncoded: false) },
                       [temporary, userFolder].map { $0.path(percentEncoded: false) })
        XCTAssertFalse(exists(directory.path(percentEncoded: false)))
        XCTAssertFalse(exists(fixture.destinationPath))
    }

    func testKnownAbsentScaffoldingThatBecomesUnobservableAfterProviderThrowsIsReported() throws {
        let fixture = try makeExportFixture()
        let temporary = fixture.directory.appendingPathComponent(".TemporaryItems", isDirectory: true)
        let userFolder = temporary.appendingPathComponent("folders.\(getuid())", isDirectory: true)
        let probe = ExportBoundaryProbe(armedFailures: [.inspectFoundationScaffolding: EACCES],
                                        armingStep: .canonicalizePrivateRoot)
        let outcome = export(to: fixture.destination, disposition: .createNew, probe: probe,
                             hooks: probe.hooks(stagingDirectory: { _ in
                                 try FileManager.default.createDirectory(
                                     at: userFolder,
                                     withIntermediateDirectories: true
                                 )
                                 throw CocoaError(.fileWriteNoPermission)
                             }), appPrivateRoot: fixture.base)
        let report = try XCTUnwrap(requireIndeterminate(outcome))
        XCTAssertEqual(report.unprovenDirectoryURLs.map { $0.path(percentEncoded: false) },
                       [temporary, userFolder].map { $0.path(percentEncoded: false) })
        XCTAssertNil(report.itemReplacementDirectoryURL)
        XCTAssertEqual(report.destinationState, .provenUnchanged)
        XCTAssertTrue(probe.calls.filter { $0.operation == .rmdir }.isEmpty)
        XCTAssertFalse(exists(fixture.destinationPath))
    }

    func testUnobservableUnrelatedScaffoldingDoesNotRejectOutsideStaging() throws {
        let fixture = try makeExportFixture()
        let probe = ExportBoundaryProbe(failures: [.inspectFoundationScaffolding: EACCES])
        let outcome = export(to: fixture.destination, disposition: .createNew, probe: probe)
        XCTAssertNotNil(requireCommitted(outcome))
        XCTAssertEqual(probe.calls(at: .inspectFoundationScaffolding).count, 4)
        XCTAssertFalse(exists(probe.stagedPath))
        XCTAssertFalse(exists(probe.stagingDirectoryPath))
        XCTAssertEqual(try entries(in: fixture.directory), ["export.html", Self.sentinelName].sorted())
    }
}
