import Foundation
@testable import PreviewKit
import XCTest

/// WebKit on iOS reads the host's actual packaged resources, never a Mac checkout path.
enum PreviewBundleFixture {
    static func indexURL() throws -> URL {
        #if os(iOS)
            let indexURL = try XCTUnwrap(
                PreviewController.defaultPreviewIndexURL(),
                "Run make ios-preview in the app-hosted IOSPreview scheme; the host must bundle preview resources"
            )
        #else
            let indexURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("App/Resources/preview/index.html")
                .standardizedFileURL
        #endif
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path), "Missing preview bundle fixture")
        return indexURL
    }
}
