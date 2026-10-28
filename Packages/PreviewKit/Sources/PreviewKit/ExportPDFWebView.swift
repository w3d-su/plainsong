import Foundation
@preconcurrency import WebKit

extension WKWebView {
    /// AppKit lays out with `layoutSubtreeIfNeeded`. UIKit's equivalent is
    /// `layoutIfNeeded`; both flush the frame the export geometry loop just set.
    func layoutExportCapture() {
        #if os(macOS)
            layoutSubtreeIfNeeded()
        #else
            setNeedsLayout()
            layoutIfNeeded()
        #endif
    }

    /// macOS WKWebView names this `pdf`; iOS names it `createPDF`. The page
    /// planner and joiner stay the same.
    func captureExportPDFPiece(_ configuration: WKPDFConfiguration) async throws -> Data {
        #if os(macOS)
            try await pdf(configuration: configuration)
        #else
            // iOS exposes the completion-handler form only.
            try await withCheckedThrowingContinuation { continuation in
                createPDF(configuration: configuration) { result in
                    continuation.resume(with: result)
                }
            }
        #endif
    }
}
