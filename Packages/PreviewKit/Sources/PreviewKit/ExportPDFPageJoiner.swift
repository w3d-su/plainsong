import CoreGraphics
import Foundation

/// Concatenates one-rect `pdf(configuration:)` captures into the single file Export as PDF… writes.
enum ExportPDFPageJoiner {
    static func join(_ pieces: [Data]) throws -> Data {
        guard !pieces.isEmpty else { throw ExportPDFCaptureError.emptyDocument }
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
                var mediaBox = page.getBoxRect(.mediaBox)
                if context == nil {
                    context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
                }
                guard let context else { throw ExportPDFCaptureError.captureFailed("pdf-context") }
                var box = mediaBox
                let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                context.drawPDFPage(page)
                context.endPDFPage()
            }
        }
        guard let context else { throw ExportPDFCaptureError.emptyDocument }
        context.closePDF()
        return output as Data
    }
}
