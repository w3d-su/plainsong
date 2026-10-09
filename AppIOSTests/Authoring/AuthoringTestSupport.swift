import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS

struct AuthoringRevealRecord: Equatable {
    let range: NSRange
    let revision: IOSDocumentRevision
    let accepted: Bool
}

@MainActor
final class AuthoringEditorFake: IOSSourceEditorControlling {
    var bindingID = UUID()
    var identity = IOSDocumentIdentity(rawValue: UUID())
    var version: Int
    var text: String
    var selection: NSRange
    var selectionGeneration: UInt64
    var accessGeneration: UInt64
    var hasMarkedText = false
    var canWrite = true
    var isFocused = true
    var beforeApply: (() -> Void)?
    var nextRefusal: IOSEditRefusal?

    private(set) var submitted: [IOSAuthorizedEdit] = []
    private(set) var outcomes: [IOSEditOutcome] = []
    private(set) var revealCalls: [AuthoringRevealRecord] = []
    private(set) var undoCount = 0
    private(set) var undoInvocations = 0
    private(set) var redoInvocations = 0
    private(set) var captureCount = 0

    var applyCount: Int {
        submitted.count
    }

    var revision: IOSDocumentRevision {
        IOSDocumentRevision(documentID: identity, version: version)
    }

    init(
        text: String,
        selection: NSRange = NSRange(location: 0, length: 0),
        version: Int = 1,
        selectionGeneration: UInt64 = 1,
        accessGeneration: UInt64 = 1
    ) {
        self.text = text
        self.selection = selection
        self.version = version
        self.selectionGeneration = selectionGeneration
        self.accessGeneration = accessGeneration
    }

    func captureSnapshot() -> IOSSourceEditorSnapshot? {
        captureCount += 1
        let storage = text as NSString
        return IOSSourceEditorSnapshot(
            bindingID: bindingID,
            revision: revision,
            document: DocumentSnapshot(
                text: text,
                version: version,
                fileKind: .markdown,
                fileURL: nil,
                isDirty: false,
                statistics: TextStatistics(text: text)
            ),
            selection: selection,
            visibleRange: NSRange(location: 0, length: storage.length),
            selectionGeneration: selectionGeneration,
            accessGeneration: accessGeneration,
            hasMarkedText: hasMarkedText,
            canWrite: canWrite,
            isFocused: isFocused
        )
    }

    func apply(_ edit: IOSAuthorizedEdit) -> IOSEditOutcome {
        submitted.append(edit)
        if let hook = beforeApply {
            beforeApply = nil
            hook()
        }
        let outcome = checkedOutcome(for: edit)
        outcomes.append(outcome)
        return outcome
    }

    func reveal(_ range: NSRange, expected: IOSDocumentRevision) -> Bool {
        let storage = text as NSString
        let accepted = !hasMarkedText && expected == revision && fits(range, length: storage.length)
        if accepted {
            selection = range
            selectionGeneration += 1
        }
        revealCalls.append(AuthoringRevealRecord(range: range, revision: expected, accepted: accepted))
        return accepted
    }

    func undo() {
        undoInvocations += 1
    }

    func redo() {
        redoInvocations += 1
    }

    private func checkedOutcome(for edit: IOSAuthorizedEdit) -> IOSEditOutcome {
        if let nextRefusal {
            self.nextRefusal = nil
            return .refused(nextRefusal)
        }
        if edit.bindingID != bindingID {
            return .refused(.bindingChanged)
        }
        if edit.baseRevision.documentID != identity {
            return .refused(.documentChanged)
        }
        if edit.baseRevision.version != version {
            return .refused(.sourceChanged)
        }
        if edit.selectionGeneration != selectionGeneration {
            return .refused(.selectionChanged)
        }
        if edit.accessGeneration != accessGeneration {
            return .refused(.accessChanged)
        }
        if hasMarkedText {
            return .refused(.markedText)
        }
        if !canWrite {
            return .refused(.readOnly)
        }
        if !isFocused {
            return .refused(.notFocused)
        }
        guard let updated = replaced(text, range: edit.result.replacementRange, with: edit.result.replacementString),
              fits(edit.result.newSelection, length: (updated as NSString).length)
        else {
            return .refused(.invalidRange)
        }
        text = updated
        selection = edit.result.newSelection
        version += 1
        selectionGeneration += 1
        undoCount += 1
        return .applied(revision)
    }

    private func replaced(_ source: String, range: NSRange, with replacement: String) -> String? {
        let storage = source as NSString
        guard fits(range, length: storage.length) else { return nil }
        return storage.replacingCharacters(in: range, with: replacement)
    }

    private func fits(_ range: NSRange, length: Int) -> Bool {
        guard range.location >= 0, range.length >= 0 else { return false }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        return !overflow && end <= length
    }
}

@MainActor
final class RecordingFindScheduler: IOSAuthoringFindScheduling {
    private struct Pending {
        let operation: @Sendable () -> EditorFindSession
        let deliver: @MainActor (EditorFindSession) -> Void
    }

    private var retained: Pending?
    private var discarded: [Pending] = []
    private(set) var startedCount = 0

    var pendingCount: Int {
        retained == nil ? 0 : 1
    }

    func schedule(
        operation: @escaping @Sendable () -> EditorFindSession,
        deliver: @escaping @MainActor (EditorFindSession) -> Void
    ) {
        if let retained {
            discarded.append(retained)
        }
        retained = Pending(operation: operation, deliver: deliver)
    }

    func finishLatest() {
        guard let retained else { return }
        self.retained = nil
        deliver(retained)
    }

    func finishDiscarded() {
        let pending = discarded
        discarded.removeAll()
        pending.forEach(deliver)
    }

    private func deliver(_ pending: Pending) {
        startedCount += 1
        pending.deliver(pending.operation())
    }
}

@MainActor
struct AuthoringHarness {
    let editor: AuthoringEditorFake
    let scheduler: RecordingFindScheduler
    let controller: IOSAuthoringController

    init(
        text: String,
        selection: NSRange = NSRange(location: 0, length: 0),
        version: Int = 1,
        selectionGeneration: UInt64 = 1,
        accessGeneration: UInt64 = 1
    ) {
        editor = AuthoringEditorFake(
            text: text,
            selection: selection,
            version: version,
            selectionGeneration: selectionGeneration,
            accessGeneration: accessGeneration
        )
        scheduler = RecordingFindScheduler()
        controller = IOSAuthoringController(findScheduler: scheduler)
    }
}

enum AuthoringFixtures {
    static func frontmatter(
        titleLine: String = "title: \"hello\"",
        extraLines: [String] = ["custom: keep"],
        body: String = "BODY",
        lineEnding: String = "\n"
    ) -> String {
        let lines = ["---", titleLine, "date: 2026-01-01", "tags: []", "draft: false"] + extraLines + ["---"]
        return lines.joined(separator: lineEnding) + lineEnding + body
    }
}
