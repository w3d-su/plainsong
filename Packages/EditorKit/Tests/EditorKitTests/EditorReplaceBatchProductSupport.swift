import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
enum EditorReplaceBatchProductSupport {
    static func prepare(
        _ ready: EditorReplaceSingleSupport.Ready,
        replacement: String
    ) throws -> EditorReplacePreparedBatch {
        try EditorReplaceBatchPreparation.prepare(
            session: ready.session,
            source: ready.fixture.model.source,
            replacement: replacement,
            selection: ready.fixture.textView.selectedRange()
        ).get()
    }

    static func perform(
        _ ready: EditorReplaceSingleSupport.Ready,
        replacement: String,
        prepared: EditorReplacePreparedBatch,
        authorization: EditorReplaceAuthorization = .allowed(),
        recheck: @MainActor () -> EditorReplaceBatchRefusal? = { nil }
    ) -> EditorReplaceBatchOutcome {
        ready.fixture.coordinator.performBatchReplace(
            EditorReplaceSingleSupport.request(
                controller: ready.controller,
                session: ready.session,
                replacement: replacement
            ),
            prepared: prepared,
            authorization: authorization,
            controller: ready.controller,
            recheck: recheck,
            in: ready.fixture.textView
        )
    }

    static func assertUnchanged(
        _ ready: EditorReplaceSingleSupport.Ready,
        selection: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(ready.fixture.model.revision, 0, file: file, line: line)
        XCTAssertEqual(ready.fixture.model.writerActivations, 0, file: file, line: line)
        XCTAssertEqual(ready.fixture.model.publications, [], file: file, line: line)
        XCTAssertEqual(ready.fixture.textView.selectedRange(), selection, file: file, line: line)
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true, file: file, line: line)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 0, file: file, line: line)
    }
}
