import Foundation
@testable import IOSAcceptanceHarness
import MarkdownCore
import PreviewKit
import WorkspaceCore
import XCTest

final class BoundedWaitTests: XCTestCase {
    func testPredicateSuccessDoesNotWaitOutTheDeadline() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        try await BoundedWait.until(timeoutNanoseconds: 1_000_000_000) { true }
        XCTAssertLessThan(clock.now - start, .milliseconds(200))
    }

    func testTimeoutStaysFailed() async {
        do {
            try await BoundedWait.until(timeoutNanoseconds: 20_000_000, pollNanoseconds: 5_000_000) {
                false
            }
            XCTFail("timeout returned")
        } catch let error as BoundedWaitError {
            XCTAssertEqual(error, .timedOut(nanoseconds: 20_000_000))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

@MainActor
final class SaveBaselineOracleTests: XCTestCase {
    func testOlderSaveKeepsNewerDraftDirtyAndLive() {
        let session = DocumentSession(text: "N")
        session.replaceText("N+1 繁中")
        let live = session.snapshot
        let effect = SaveBaselineOracle().acknowledge(
            session: session,
            order: 1,
            capturedVersion: 0,
            persistedText: "N"
        )
        XCTAssertTrue(effect.applied)
        XCTAssertEqual(session.text, live.text)
        XCTAssertEqual(session.version, live.version)
        XCTAssertTrue(session.isDirty)
    }

    func testLateOlderCompletionCannotCleanANewerAcknowledgement() {
        let session = DocumentSession(text: "N")
        session.replaceText("N+1")
        let oracle = SaveBaselineOracle()
        let saved = oracle.acknowledge(
            session: session,
            order: 2,
            capturedVersion: 1,
            persistedText: "N+1"
        )
        XCTAssertTrue(saved.applied)
        XCTAssertFalse(session.isDirty)
        let late = oracle.acknowledge(
            session: session,
            order: 1,
            capturedVersion: 0,
            persistedText: "N"
        )
        XCTAssertFalse(late.applied)
        XCTAssertEqual(session.text, "N+1")
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.version, saved.version)
    }

    func testDirtyDraftIsNotReplacedByExternalBytes() {
        let session = DocumentSession(text: "mine")
        session.replaceText("mine plus")
        let effect = SaveBaselineOracle().acknowledge(
            session: session,
            order: 1,
            capturedVersion: session.version,
            persistedText: "disk"
        )
        XCTAssertTrue(effect.applied)
        XCTAssertEqual(session.text, "mine plus")
        XCTAssertTrue(session.isDirty)
    }

    func testMarkSavedWouldClobberButTheOracleDoesNotCallIt() {
        let clobber = DocumentSession(text: "N")
        clobber.replaceText("N+1")
        clobber.markSaved(text: "N", url: nil)
        XCTAssertEqual(clobber.text, "N")
        XCTAssertFalse(clobber.isDirty)

        let session = DocumentSession(text: "N")
        session.replaceText("N+1")
        _ = SaveBaselineOracle().acknowledge(
            session: session,
            order: 1,
            capturedVersion: 0,
            persistedText: "N"
        )
        XCTAssertEqual(session.text, "N+1")
        XCTAssertTrue(session.isDirty)
    }
}

final class AuthoringAcceptanceTests: XCTestCase {
    func testUnicodeSingleReplaceEditsOnlyTheCurrentMatch() {
        let source = "see 👩‍💻 and 👩‍💻"
        var probe = EditorProbe(source: source, selection: NSRange(location: 0, length: 0))
        let authority = authority(source: source)
        let applied = AuthoringAcceptance.singleReplace(
            probe: &probe,
            captured: authority,
            live: authority,
            pattern: "👩‍💻",
            replacement: "工程師"
        )
        XCTAssertTrue(applied)
        XCTAssertEqual(probe.source, "see 工程師 and 👩‍💻")
        XCTAssertEqual(probe.undoRegistrations, 1)
        XCTAssertEqual(probe.selection.length, 0)
        XCTAssertGreaterThan(probe.selection.location, 0)
    }

    func testStaleSourceAndMissingAuthorityLeaveSourceSelectionAndUndoUntouched() {
        let source = "家族 👩‍💻"
        let selection = NSRange(location: 0, length: 2)
        var probe = EditorProbe(source: source, selection: selection)
        let captured = authority(source: source, selection: selection)
        var stale = captured
        stale.source = "家族 changed"
        var probeForStale = probe
        XCTAssertFalse(
            AuthoringAcceptance.singleReplace(
                probe: &probeForStale,
                captured: captured,
                live: stale,
                pattern: "👩‍💻",
                replacement: "工程師"
            )
        )
        XCTAssertEqual(probeForStale, probe)

        var otherDocument = captured
        otherDocument.documentID = IOSDocumentIdentity(rawValue: UUID())
        XCTAssertFalse(
            AuthoringAcceptance.singleReplace(
                probe: &probe,
                captured: captured,
                live: otherDocument,
                pattern: "👩‍💻",
                replacement: "x"
            )
        )
        var movedSelection = captured
        movedSelection.selectionGeneration += 1
        movedSelection.selection = NSRange(location: 1, length: 0)
        var movedProbe = probe
        XCTAssertFalse(
            AuthoringAcceptance.singleReplace(
                probe: &movedProbe,
                captured: captured,
                live: movedSelection,
                pattern: "👩‍💻",
                replacement: "x"
            )
        )
        XCTAssertEqual(movedProbe, probe)

        XCTAssertFalse(
            AuthoringAcceptance.singleReplace(
                probe: &probe,
                captured: captured,
                live: captured,
                pattern: "不存在",
                replacement: "x"
            )
        )
        XCTAssertFalse(
            AuthoringAcceptance.singleReplace(
                probe: &probe,
                captured: captured,
                live: captured,
                pattern: "👩‍💻",
                replacement: "line\nbreak"
            )
        )
        XCTAssertEqual(probe.source, source)
        XCTAssertEqual(probe.selection, selection)
        XCTAssertEqual(probe.undoRegistrations, 0)
    }

    func testFrontmatterRoundTripPreservesLiteralsAndInvalidYAMLIsNotRewritten() throws {
        let original = "---\ntitle: \"old\"\n---\nbody\n"
        let rewritten = try XCTUnwrap(
            Frontmatter.updating(original, key: "title", value: .string("標題: \"quoted\""))
        )
        XCTAssertNotEqual(rewritten, original)
        let parsed = Frontmatter.parse(rewritten)
        XCTAssertFalse(parsed.isMalformed)
        XCTAssertEqual(parsed.block?.fieldValues["title"], .string("標題: \"quoted\""))

        let broken = "---\n- item\n---\nkeep\n"
        XCTAssertTrue(Frontmatter.parse(broken).isMalformed)
        XCTAssertNil(Frontmatter.updating(broken, key: "title", value: .string("x")))
        XCTAssertEqual(broken, "---\n- item\n---\nkeep\n")
    }

    private func authority(
        source: String,
        selection: NSRange = NSRange(location: 0, length: 0)
    ) -> AuthoringAuthority {
        AuthoringAuthority(
            bindingID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            documentID: IOSDocumentIdentity(
                rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            ),
            version: 3,
            selectionGeneration: 4,
            source: source,
            selection: selection
        )
    }
}

final class WorkspaceAndPreviewTests: XCTestCase {
    func testSingleFileGrantDoesNotAuthorizeParentSiblingOrAnotherRoot() {
        XCTAssertEqual(WorkspaceRelativePath.rejection(for: "../secret"), .parentTraversal)
        XCTAssertFalse(WorkspaceAuthorityCheck.singleFileAllows(grantedRelativePath: "note.md", requested: "../secret"))
        XCTAssertFalse(
            WorkspaceAuthorityCheck.singleFileAllows(
                grantedRelativePath: "note.md",
                requested: "assets/pixel.png"
            )
        )
        XCTAssertTrue(WorkspaceAuthorityCheck.singleFileAllows(grantedRelativePath: "note.md", requested: "note.md"))

        let workspace = IOSWorkspaceIdentity(rawValue: UUID())
        let other = IOSWorkspaceIdentity(rawValue: UUID())
        let url = URL(fileURLWithPath: "/tmp/plainsong-acceptance/note.md")
        let granted = IOSFileLocation(
            workspaceID: workspace,
            accessGeneration: 2,
            relativePath: "note.md",
            fileURL: url,
            resourceID: nil
        )
        let sameURLOtherRoot = IOSFileLocation(
            workspaceID: other,
            accessGeneration: 2,
            relativePath: "note.md",
            fileURL: url,
            resourceID: nil
        )
        XCTAssertEqual(granted.fileURL, sameURLOtherRoot.fileURL)
        XCTAssertFalse(WorkspaceAuthorityCheck.sameGrant(granted, sameURLOtherRoot))
    }

    @MainActor
    func testSameVersionDocumentSwitchDropsThePreviousAssetRoot() {
        let controller = PreviewController()
        defer { controller.invalidate() }
        let rootA = URL(fileURLWithPath: "/tmp/plainsong-acceptance-root-a", isDirectory: true)
        let rootB = URL(fileURLWithPath: "/tmp/plainsong-acceptance-root-b", isDirectory: true)
        let documentA = IOSDocumentIdentity(rawValue: UUID())
        let documentB = IOSDocumentIdentity(rawValue: UUID())
        let accessA = PreviewAssetAccessContext(
            allowedRoot: rootA,
            rootToken: UUID(),
            grantIdentity: UUID(),
            accessGeneration: 1
        )
        let accessB = PreviewAssetAccessContext(
            allowedRoot: rootB,
            rootToken: UUID(),
            grantIdentity: UUID(),
            accessGeneration: 1
        )
        let first = DocumentSession(text: "alpha", url: rootA.appendingPathComponent("a.md"))
        let second = DocumentSession(text: "beta", url: rootB.appendingPathComponent("b.md"))
        XCTAssertEqual(first.version, second.version)
        XCTAssertNotEqual(documentA, documentB)
        controller.render(first.snapshot, identity: documentA, assetAccess: accessA)
        XCTAssertTrue(controller.isCurrent(accessA))
        controller.render(second.snapshot, identity: documentB, assetAccess: accessB)
        XCTAssertFalse(controller.isCurrent(accessA))
        XCTAssertTrue(controller.isCurrent(accessB))
        XCTAssertNotEqual(first.text, second.text)
    }
}

final class GateLedgerTests: XCTestCase {
    func testProductGatesStayOpenOrBlocked() {
        XCTAssertFalse(ProductGateLedger.gates.isEmpty)
        XCTAssertTrue(ProductGateLedger.gates.allSatisfy { $0.status == .open || $0.status == .blocked })
        XCTAssertFalse(ProductGateLedger.gates.contains { $0.status == .pass || $0.status == .fail })
        XCTAssertFalse(AcceptanceDebugSeam.isEnabled)
        XCTAssertFalse(AcceptanceDebugSeam.releaseCanEnable())
    }

    func testTextDidChangeAndShortRunsCannotClosePerformance() {
        let callbackOnly = (0 ..< 60).map { _ in
            sample(kind: .textDidChangeOnly, visible: false, environment: "owner-idle-device")
        }
        XCTAssertEqual(
            PerformanceSampleLedger.verdict(samples: callbackOnly, kind: .textDidChangeOnly),
            .open("textDidChange duration is not input-to-screen")
        )
        let tooFew = [sample(kind: .inputToScreen, visible: true, environment: "owner-idle-device")]
        XCTAssertEqual(
            PerformanceSampleLedger.verdict(samples: tooFew, kind: .inputToScreen),
            .open("fewer than 60 visible-presentation samples")
        )
        let simulator = (0 ..< 60).map { _ in
            sample(kind: .inputToScreen, visible: true, environment: "simulator")
        }
        XCTAssertEqual(
            PerformanceSampleLedger.verdict(samples: simulator, kind: .inputToScreen),
            .diagnostic(count: 60)
        )
        let owner = (0 ..< 60).map { _ in
            sample(kind: .renderCompletion, visible: true, environment: "owner-idle-device")
        }
        XCTAssertEqual(
            PerformanceSampleLedger.verdict(samples: owner, kind: .renderCompletion),
            .diagnostic(count: 60)
        )
    }

    func testExistingResultScriptRejectsEmptySkipAndMissingCases() throws {
        let root = try XCTUnwrap(AcceptanceRepository.root(startingAt: URL(fileURLWithPath: #filePath)))
        let script = root.appendingPathComponent("Scripts/ios/ios-test-results.py")
        let lease = try FixtureLease()
        defer { try? lease.cleanup() }
        let required = try lease.write(
            relativePath: "required.txt",
            data: Data("IOSAcceptanceLaunchSmokeTests/testLaunchShowsUnavailableScaffold\n".utf8)
        )
        let report = lease.root.appendingPathComponent("report.json")
        let names = lease.root.appendingPathComponent("names.txt")

        let empty = try lease.write(relativePath: "empty.json", data: Data("{\"testNodes\":[]}\n".utf8))
        XCTAssertEqual(try run(script, results: empty, required: required, report: report, names: names), 65)

        let skipped = """
        {"testNodes":[{"nodeType":"Test Case","nodeIdentifier":"IOSAcceptanceLaunchSmokeTests/testLaunchShowsUnavailableScaffold()","result":"Skipped","children":[]}]}
        """
        let skippedURL = try lease.write(relativePath: "skipped.json", data: Data(skipped.utf8))
        XCTAssertEqual(try run(script, results: skippedURL, required: required, report: report, names: names), 65)

        let passed = skipped.replacingOccurrences(of: "Skipped", with: "Passed")
        let passedURL = try lease.write(relativePath: "passed.json", data: Data(passed.utf8))
        XCTAssertEqual(try run(script, results: passedURL, required: required, report: report, names: names), 0)
    }

    private func sample(
        kind: PerformanceMeasureKind,
        visible: Bool,
        environment: String
    ) -> PerformanceSample {
        PerformanceSample(
            kind: kind,
            milliseconds: 1,
            fixture: "Fixtures/perf-100kb.md",
            includesVisiblePresentation: visible,
            thermalState: "nominal",
            lowPowerMode: false,
            operatingSystem: "unmeasured",
            configuration: "unmeasured",
            environment: environment
        )
    }

    private func run(
        _ script: URL,
        results: URL,
        required: URL,
        report: URL,
        names: URL
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            script.path,
            results.path,
            "--required", required.path,
            "--report", report.path,
            "--names", names.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
