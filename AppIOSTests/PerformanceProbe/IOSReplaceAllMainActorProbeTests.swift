import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import SyntaxKit
import UIKit
import XCTest

/// Temporary measurement probe: how long iOS Replace All holds the main actor.
@MainActor
final class IOSReplaceAllMainActorProbeTests: XCTestCase {
    private static let line = "Lorem ipsum dolor sit amet, consectetur adipiscing elit sed do.\n"
    private static let matchLine = "Lorem ipsum alpha sit amet, consectetur adipiscing elit sed do.\n"

    func testMeasureReplaceAllMainActorCost() async throws {
        let sizes = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024]
        let matchCounts = [2, 1000, 10000]
        guard let reps = ProcessInfo.processInfo.environment["PROBE_REPS"], let repetitions = Int(reps) else {
            throw XCTSkip("Set TEST_RUNNER_PROBE_REPS to run this probe.")
        }
        print("PROBE_ENV device=\(UIDevice.current.model) system=\(UIDevice.current.systemVersion)")
        for size in sizes {
            for matches in matchCounts {
                guard matches <= size / Self.line.utf8.count else {
                    print("PROBE_SKIP bytes=\(size) matches=\(matches) reason=fewer-lines-than-matches")
                    continue
                }
                for rep in 0 ... repetitions {
                    let row = try await measure(bytes: size, matches: matches)
                    if rep == 0 {
                        continue
                    } // warm-up
                    print("PROBE_ROW bytes=\(size) matches=\(matches) rep=\(rep) \(row)")
                }
            }
        }
    }

    private func fixture(bytes: Int, matches: Int) -> String {
        let lineCount = bytes / Self.line.utf8.count
        let stride = max(1, lineCount / matches)
        var lines = [String]()
        lines.reserveCapacity(lineCount)
        var placed = 0
        for index in 0 ..< lineCount {
            if index % stride == 0, placed < matches {
                lines.append(Self.matchLine)
                placed += 1
            } else {
                lines.append(Self.line)
            }
        }
        return lines.joined()
    }

    private func ms(_ start: UInt64) -> String {
        String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private func findSession(
        _ authoring: IOSAuthoringController,
        editor: TimedEditor,
        expected: Int
    ) async throws -> EditorFindSession {
        authoring.setFindQuery("alpha", using: editor)
        let deadline = Date().addingTimeInterval(60)
        while authoring.find.status != .matches || authoring.find.session == nil {
            guard Date() < deadline else { throw XCTSkip("find timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let session = try XCTUnwrap(authoring.find.session)
        XCTAssertEqual(session.total, expected)
        authoring.setReplacement("omega")
        return session
    }

    /// Mirrors one ExactSourceFragment check in IOSSourceEditorController.refusal(for:);
    /// apply runs it twice on the unchanged text before the native edit.
    private func applyGuardMS(_ host: ProbeEditorHost) -> String {
        let mark = now()
        _ = (host.controller.textView.textStorage.string as NSString)
            .compare(host.session.text, options: .literal) == .orderedSame
        return ms(mark)
    }

    private func measure(bytes: Int, matches: Int) async throws -> String {
        let text = fixture(bytes: bytes, matches: matches)
        let host = try ProbeEditorHost(text: text)
        defer { host.tearDown() }
        let timed = TimedEditor(host.controller)
        let authoring = IOSAuthoringController()
        let session = try await findSession(authoring, editor: timed, expected: matches)

        // Pure phases on identical inputs, timed separately (no mutation).
        var mark = now()
        let snapshot = try XCTUnwrap(host.controller.captureSnapshot())
        let capture = ms(mark)
        mark = now()
        guard case let .success(plan) = EditorReplacePlanner.planBatch(
            session: session, source: snapshot.document.text, replacement: "omega"
        ) else { throw XCTSkip("plan refused") }
        let planning = ms(mark)
        let enclosing = try XCTUnwrap(plan.enclosingRange)
        mark = now()
        _ = EditorReplaceSourceConstruction.replacedSlice(
            snapshot.document.text, enclosing: enclosing,
            ranges: plan.differingRanges, replacement: "omega"
        )
        let slice = ms(mark)
        mark = now()
        let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
            snapshot.document.text, ranges: plan.differingRanges, replacement: "omega"
        ))
        let source = ms(mark)
        mark = now()
        _ = EditorReplaceContinuationPlanning.afterBatch(
            plan: plan, preWriteCurrentMatch: session.currentMatch,
            preWriteCaretUTF16: snapshot.selection.location, postWriteSource: post
        )
        let rescan = ms(mark)
        let guardCheck = applyGuardMS(host)

        // The real command, end to end, synchronously on the main actor.
        timed.reset()
        mark = now()
        authoring.perform(.replaceAll, using: timed)
        let total = ms(mark)
        mark = now()
        host.controller.textView.layoutIfNeeded()
        let layout = ms(mark)
        XCTAssertEqual(authoring.find.message, "Replaced \(matches) matches.")

        let latest = try XCTUnwrap(host.controller.captureSnapshot())
        mark = now()
        _ = ExactSourceText.matches(latest.document.text, post)
        let verify = ms(mark)

        return "total=\(total) apply=\(timed.applyMS) captures=\(timed.captureMS) " +
            "captureCount=\(timed.captureCount) capture1=\(capture) " +
            "plan=\(planning) slice=\(slice) source=\(source) rescan=\(rescan) " +
            "verify=\(verify) applyGuard=\(guardCheck) layoutAfter=\(layout)"
    }
}

@MainActor
private final class TimedEditor: IOSSourceEditorControlling {
    let base: IOSSourceEditorController
    private(set) var applyNanos: UInt64 = 0
    private(set) var captureNanos: UInt64 = 0
    private(set) var captureCount = 0

    init(_ base: IOSSourceEditorController) {
        self.base = base
    }

    func reset() {
        applyNanos = 0
        captureNanos = 0
        captureCount = 0
    }

    var applyMS: String {
        String(format: "%.2f", Double(applyNanos) / 1_000_000)
    }

    var captureMS: String {
        String(format: "%.2f", Double(captureNanos) / 1_000_000)
    }

    func captureSnapshot() -> IOSSourceEditorSnapshot? {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            captureNanos += DispatchTime.now().uptimeNanoseconds - start
            captureCount += 1
        }
        return base.captureSnapshot()
    }

    func apply(_ edit: IOSAuthorizedEdit) -> IOSEditOutcome {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { applyNanos += DispatchTime.now().uptimeNanoseconds - start }
        return base.apply(edit)
    }

    func reveal(_ range: NSRange, expected: IOSDocumentRevision) -> Bool {
        base.reveal(range, expected: expected)
    }

    func undo() {
        base.undo()
    }

    func redo() {
        base.redo()
    }
}

@MainActor
private final class ProbeEditorHost {
    let window: UIWindow
    let controller: IOSSourceEditorController
    let session: DocumentSession
    let identity = IOSDocumentIdentity(rawValue: UUID())
    let bindingID = UUID()
    private let root = UIViewController()

    init(text: String) throws {
        session = DocumentSession(text: text, isDirty: false)
        controller = try IOSSourceEditorController(syntaxTokenizer: MarkdownSyntaxTokenizer())
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        controller.textView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        root.view.addSubview(controller.textView)
        controller.attach(IOSSourceEditorDocumentBinding(
            bindingID: bindingID, identity: identity, session: session,
            accessGeneration: 1, canWrite: true
        ))
        controller.updateCommandFocus(for: identity, bindingID: bindingID, isFocused: true)
        _ = controller.textView.becomeFirstResponder()
        controller.textView.layoutIfNeeded()
    }

    func tearDown() {
        controller.detach(expected: identity, bindingID: bindingID)
        controller.textView.removeFromSuperview()
        window.isHidden = true
    }
}
