import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
final class MarkdownSyntaxThemeConcurrencyTests: XCTestCase {
    func testDynamicColorResolvesWhileTheMainThreadWaitsForItsWorker() async throws {
        let previous = EditorThemeDynamicColor.increaseContrast.withLock { $0 }
        defer { MarkdownSyntaxTheme.noteAccessibilityIncreaseContrast(previous) }
        let document = try CustomThemeValidation.validate(Data("""
        {"schemaVersion":1,"id":"background-resolve","name":"Background Resolve",
         "light":{"editor":{"text":"#112233"}}}
        """.utf8)).get()
        let color = MarkdownSyntaxTheme.resolving(document).textColor
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        var builtInRed: CGFloat?
        appearance.performAsCurrentDrawingAppearance {
            builtInRed = MarkdownSyntaxTheme.standard.textColor.usingColorSpace(.sRGB)?.redComponent
        }

        for increaseContrast in [false, true] {
            MarkdownSyntaxTheme.noteAccessibilityIncreaseContrast(increaseContrast)
            let completed = DispatchSemaphore(value: 0)
            let worker = Task.detached {
                var red: CGFloat?
                appearance.performAsCurrentDrawingAppearance {
                    red = color.usingColorSpace(.sRGB)?.redComponent
                }
                completed.signal()
                return red
            }
            // A provider that uses main.sync cannot finish until this bounded wait ends.
            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
            let workerRed = await worker.value
            let resolvedRed = try XCTUnwrap(workerRed)
            let expectedRed = increaseContrast ? try XCTUnwrap(builtInRed) : 0x11 / 255.0
            XCTAssertEqual(resolvedRed, expectedRed, accuracy: 0.02)
        }
    }
}
