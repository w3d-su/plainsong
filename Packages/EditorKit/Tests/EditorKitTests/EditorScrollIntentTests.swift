@testable import EditorKit
import STTextView
import XCTest

@MainActor
final class EditorScrollIntentTests: XCTestCase {
    func testExplicitNavigationIsNotDeduplicatedAgainstViewportReceipt() {
        let textView = STTextView(frame: .zero)
        textView.text = "one\ntwo\nthree\n"
        let proxy = EditorScrollProxy()
        var emittedIntents: [EditorScrollIntent] = []
        proxy.onScrollIntent = { emittedIntents.append($0) }
        proxy.attach(to: textView)
        emittedIntents.removeAll()
        let thirdLineOffset = "one\ntwo\n".utf16.count

        proxy.emitVisibleLine(containingUTF16Offset: thirdLineOffset, in: textView)
        proxy.emitNavigationLine(containingUTF16Offset: thirdLineOffset, in: textView)
        proxy.emitNavigationLine(containingUTF16Offset: thirdLineOffset, in: textView)

        XCTAssertEqual(emittedIntents, [
            .viewportChanged(line: 3),
            .navigation(line: 3),
            .navigation(line: 3),
        ])
    }
}
