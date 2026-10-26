@testable import PlainsongIOSM0
import XCTest

final class ReplacementTests: XCTestCase {
    @MainActor
    func testNonUTF8ReplacementRetainsWorkingSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let invalid = directory.appendingPathComponent("invalid.txt")
        try Data("# Original 中文".utf8).write(to: first)
        try Data([0xFF, 0xFE, 0x00]).write(to: invalid)
        let grant = try AccessGrant(root: first, scope: .singleFile, appPrivate: true)
        let session = DocumentSession(editor: SourceEditor(), probe: Probe())
        await session.open(url: first, grant: grant)
        let previous = try XCTUnwrap(session.document)
        let identity = session.editor.documentID
        let revision = session.editor.revision
        session.editor.textView.selectedRange = NSRange(location: 2, length: 3)
        let selection = session.editor.textView.selectedRange
        try await session.open(url: invalid, grant: AccessGrant(root: invalid, scope: .singleFile, appPrivate: true))
        XCTAssertTrue(session.document === previous)
        XCTAssertTrue(session.grant === grant)
        XCTAssertEqual(session.editor.textView.text, "# Original 中文")
        XCTAssertEqual(session.editor.documentID, identity)
        XCTAssertEqual(session.editor.revision, revision)
        XCTAssertEqual(session.editor.textView.selectedRange, selection)
        XCTAssertTrue(session.editor.textView.isEditable)
        XCTAssertFalse(previous.documentState.contains(.closed))
        XCTAssertFalse(session.opening)
        XCTAssertFalse(session.dirty)
        await close(session)
    }

    @MainActor
    func testCloseFailureRetainsEditableWorkingSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let grant = try AccessGrant(root: first, scope: .singleFile, appPrivate: true)
        let session = DocumentSession(editor: SourceEditor(), probe: Probe(), closeForReplacement: { _ in false })
        await session.open(url: first, grant: grant)
        let previous = try XCTUnwrap(session.document)
        let identity = session.editor.documentID
        try await session.open(url: second, grant: AccessGrant(root: second, scope: .singleFile, appPrivate: true))
        XCTAssertTrue(session.document === previous)
        XCTAssertTrue(session.grant === grant)
        XCTAssertEqual(session.editor.textView.text, "first")
        XCTAssertEqual(session.editor.documentID, identity)
        XCTAssertTrue(session.editor.textView.isEditable)
        XCTAssertFalse(previous.documentState.contains(.closed))
        XCTAssertFalse(session.opening)
        XCTAssertTrue(session.message.contains("Close failed"))
        await close(session)
    }

    @MainActor
    func testChangedSourceDuringCloseIsNotReplaced() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let editor = SourceEditor()
        let session = DocumentSession(editor: editor, probe: Probe(), closeForReplacement: { document in
            let closed: Bool = await withCheckedContinuation { continuation in
                document.close { continuation.resume(returning: $0) }
            }
            editor.textView.text = "late original edit"
            editor.textViewDidChange(editor.textView)
            return closed
        })
        let grant = try AccessGrant(root: first, scope: .singleFile, appPrivate: true)
        await session.open(url: first, grant: grant)
        let previous = try XCTUnwrap(session.document)
        let identity = editor.documentID
        try await session.open(url: second, grant: AccessGrant(root: second, scope: .singleFile, appPrivate: true))
        XCTAssertTrue(session.document === previous)
        XCTAssertTrue(session.grant === grant)
        XCTAssertEqual(editor.textView.text, "late original edit")
        XCTAssertEqual(editor.documentID, identity)
        XCTAssertTrue(session.dirty)
        XCTAssertTrue(editor.textView.isEditable)
        XCTAssertFalse(previous.documentState.contains(.closed))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        await close(session)
    }

    @MainActor
    func testSuccessfulReplacementAttachesNewDocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let session = DocumentSession(editor: SourceEditor(), probe: Probe())
        try await session.open(url: first, grant: AccessGrant(root: first, scope: .singleFile, appPrivate: true))
        let previous = try XCTUnwrap(session.document)
        let identity = session.editor.documentID
        let grant = try AccessGrant(root: second, scope: .singleFile, appPrivate: true)
        await session.open(url: second, grant: grant)
        XCTAssertFalse(session.document === previous)
        XCTAssertTrue(session.grant === grant)
        XCTAssertEqual(session.editor.textView.text, "second")
        XCTAssertNotEqual(session.editor.documentID, identity)
        XCTAssertTrue(session.editor.textView.isEditable)
        XCTAssertFalse(session.dirty)
        XCTAssertTrue(previous.documentState.contains(.closed))
        await close(session)
    }

    @MainActor
    func testFailedCandidateCloseRetainsGrantUntilRetrySucceeds() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        var discardFails = true
        let session = DocumentSession(editor: SourceEditor(), probe: Probe(),
                                      closeForReplacement: { _ in false }, closeDiscardedCandidate: { document in
                                          guard !discardFails else { return false }
                                          return await withCheckedContinuation { continuation in
                                              document.close { continuation.resume(returning: $0) }
                                          }
                                      })
        try await session.open(url: first, grant: AccessGrant(root: first, scope: .singleFile, appPrivate: true))
        var selectedGrant: AccessGrant? = try AccessGrant(root: second, scope: .singleFile, appPrivate: true)
        weak var candidateGrant = selectedGrant
        try await session.open(url: second, grant: XCTUnwrap(selectedGrant))
        selectedGrant = nil
        XCTAssertNotNil(candidateGrant)
        try await session.open(url: second, grant: AccessGrant(root: second, scope: .singleFile, appPrivate: true))
        XCTAssertTrue(session.message.contains("Candidate close is still pending"))
        XCTAssertEqual(session.editor.textView.text, "first")
        XCTAssertTrue(session.editor.textView.isEditable)
        discardFails = false
        try await session.open(url: second, grant: AccessGrant(root: second, scope: .singleFile, appPrivate: true))
        XCTAssertNil(candidateGrant)
        XCTAssertEqual(session.editor.textView.text, "first")
        await close(session)
    }

    @MainActor
    func testInitialOpenFailureLeavesNoEditableDocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = directory.appendingPathComponent("invalid.txt")
        try Data([0xFF]).write(to: invalid)
        let editor = SourceEditor()
        editor.textView.isEditable = false
        let session = DocumentSession(editor: editor, probe: Probe())
        try await session.open(url: invalid, grant: AccessGrant(root: invalid, scope: .singleFile, appPrivate: true))
        XCTAssertNil(session.document)
        XCTAssertNil(session.grant)
        XCTAssertNil(session.ledger)
        XCTAssertFalse(editor.textView.isEditable)
        XCTAssertFalse(session.opening)
    }

    func testFixtureIsBundledAsUTF8() throws {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "m0", withExtension: "md"))
        let data = try Data(contentsOf: fixture)
        XCTAssertFalse(data.isEmpty)
        XCTAssertNotNil(String(data: data, encoding: .utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func close(_ session: DocumentSession) async {
        guard let document = session.document else { return }
        document.requestAutosave = { $0(true) }
        let success: Bool = await withCheckedContinuation { continuation in
            document.close { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(success)
    }
}
