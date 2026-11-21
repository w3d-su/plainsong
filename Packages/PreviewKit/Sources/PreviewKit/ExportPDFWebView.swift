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
}

/// One page capture in flight. WebKit's completion, the timeout, cancellation,
/// `invalidate()` and a WebContent termination each try to resolve it; the first wins.
@MainActor
final class PendingExportPDFPiece {
    private var continuation: CheckedContinuation<Data, Error>?
    var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}

struct ExportPDFPieceCapture {
    typealias Capturer = @MainActor (WKPDFConfiguration, @escaping @MainActor (Result<Data, Error>) -> Void) -> Void

    /// One page is one WebKit call; a renderer that never answers must not hang the export.
    var timeoutNanoseconds: UInt64 = 60_000_000_000
    /// Test seam: replaces WebKit's `createPDF`.
    var capturer: Capturer?
    var pending: PendingExportPDFPiece?
}

extension PreviewController {
    /// WebKit's `createPDF` has no timeout and does not observe task cancellation. The wait
    /// here ends on whichever comes first; a late WebKit completion is then ignored.
    func captureExportPDFPiece(_ configuration: WKPDFConfiguration) async throws -> Data {
        let box = PendingExportPDFPieceBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let piece = PendingExportPDFPiece(continuation)
                box.piece = piece
                pdfPieceCapture.pending = piece
                let timeout = pdfPieceCapture.timeoutNanoseconds
                piece.timeoutTask = Task {
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    piece.resolve(.failure(ExportPDFCaptureError.captureFailed("timeout")))
                }
                let finish: @MainActor (Result<Data, Error>) -> Void = { [weak self] result in
                    piece.resolve(result)
                    if self?.pdfPieceCapture.pending === piece {
                        self?.pdfPieceCapture.pending = nil
                    }
                }
                if let capturer = pdfPieceCapture.capturer {
                    capturer(configuration, finish)
                } else {
                    webView.createPDF(configuration: configuration) { result in
                        Task { @MainActor in finish(result) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in box.piece?.resolve(.failure(CancellationError())) }
        }
    }

    /// `invalidate()` and a WebContent termination wake the page capture; the capture
    /// loop's `checkExportAlive()` then reports which one it was.
    func failPendingExportPDFPiece() {
        let piece = pdfPieceCapture.pending
        pdfPieceCapture.pending = nil
        piece?.resolve(.failure(CancellationError()))
    }
}

@MainActor
private final class PendingExportPDFPieceBox {
    var piece: PendingExportPDFPiece?
}
