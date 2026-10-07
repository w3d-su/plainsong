import CoreGraphics
import Foundation

/// Concatenates one-rect `pdf(configuration:)` captures into the single file Export as
/// PDF… writes. `scale` is the uniform PDF-space factor from
/// `ExportPDFPagePlanner.uniformScale`: every output media box is the captured box
/// scaled down, and the context scales the captured page into it, so an over-maximum
/// width still fits the 14,400 pt default user space. Drawing through the CTM keeps
/// text vector and extractable.
enum ExportPDFPageJoiner {
    static func join(_ pieces: [Data], scale: CGFloat) throws -> Data {
        guard !pieces.isEmpty else { throw ExportPDFCaptureError.emptyDocument }
        guard scale > 0, scale.isFinite else {
            throw ExportPDFCaptureError.captureFailed("pdf-scale")
        }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else {
            throw ExportPDFCaptureError.captureFailed("pdf-consumer")
        }
        var context: CGContext?
        for piece in pieces {
            guard let provider = CGDataProvider(data: piece as CFData),
                  let document = CGPDFDocument(provider),
                  document.numberOfPages > 0
            else { throw ExportPDFCaptureError.captureFailed("pdf-parse") }
            for number in 1 ... document.numberOfPages {
                guard let page = document.page(at: number) else {
                    throw ExportPDFCaptureError.captureFailed("pdf-page")
                }
                let pieceBox = page.getBoxRect(.mediaBox)
                var mediaBox = CGRect(
                    x: pieceBox.origin.x * scale,
                    y: pieceBox.origin.y * scale,
                    width: pieceBox.width * scale,
                    height: pieceBox.height * scale
                )
                if context == nil {
                    context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
                }
                guard let context else { throw ExportPDFCaptureError.captureFailed("pdf-context") }
                var box = mediaBox
                let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                context.saveGState()
                if scale != 1 {
                    context.scaleBy(x: scale, y: scale)
                }
                context.drawPDFPage(page)
                context.restoreGState()
                context.endPDFPage()
            }
        }
        guard let context else { throw ExportPDFCaptureError.emptyDocument }
        context.closePDF()
        return output as Data
    }
}
