@testable import PlainsongIOS
import XCTest

@MainActor
final class IOSTypewriterSyncTests: XCTestCase {
    func testEditorScrollIsIgnoredUntilPreviewCanBeSeen() {
        let sync = IOSTypewriterSync()
        var preview: [Int] = []
        sync.scrollPreview = { preview.append($0) }
        sync.editorViewportChanged(to: 4)
        XCTAssertTrue(preview.isEmpty)
        sync.setEnabled(true, editorLine: 6)
        XCTAssertEqual(preview, [6])
    }

    func testPreviewEchoDoesNotScrollTheEditorUntilTheOwnerDecays() {
        let sync = IOSTypewriterSync()
        var time: UInt64 = 1000
        sync.installClockForTesting { time }
        var preview: [Int] = []
        var editor: [Int] = []
        sync.scrollPreview = { preview.append($0) }
        sync.scrollEditor = { editor.append($0) }
        sync.setEnabled(true, editorLine: nil)
        sync.editorViewportChanged(to: 4)
        sync.previewScrolled(to: 9)
        XCTAssertEqual(preview, [4])
        XCTAssertTrue(editor.isEmpty)
        time += IOSTypewriterSync.ownerDecayNanoseconds
        sync.previewScrolled(to: 9)
        XCTAssertEqual(editor, [9])
        sync.editorViewportChanged(to: 3)
        XCTAssertEqual(preview, [4])
    }

    func testDisablingDropsBothDirections() {
        let sync = IOSTypewriterSync()
        var preview: [Int] = []
        var editor: [Int] = []
        sync.scrollPreview = { preview.append($0) }
        sync.scrollEditor = { editor.append($0) }
        sync.setEnabled(true, editorLine: nil)
        sync.setEnabled(false, editorLine: 2)
        sync.editorViewportChanged(to: 8)
        sync.previewScrolled(to: 3)
        XCTAssertTrue(preview.isEmpty)
        XCTAssertTrue(editor.isEmpty)
    }

    func testPreviewVisibilityFollowsTheLayout() {
        XCTAssertFalse(IOSContentLayout.single(.source).showsPreview)
        XCTAssertTrue(IOSContentLayout.single(.preview).showsPreview)
        XCTAssertTrue(IOSContentLayout.sideBySide.showsPreview)
    }
}
