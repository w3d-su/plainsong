import PreviewKit

/// PDF/Print wording for `ExportHTMLNoticeMapper`, kept in an extension to keep the main
/// feedback file inside the lint length budget.
extension ExportHTMLNoticeMapper {
    static func failureTitle(for product: ExportCommandProduct) -> String {
        switch product {
        case .html: failureTitle
        case .pdf: "Could Not Export as PDF"
        case .print: "Could Not Print"
        }
    }

    /// Every `ExportPDFCaptureError` case gets an actionable, product-aware line; the
    /// oversize-atomic and positioned-content causes are named directly rather than
    /// hidden behind the generic render failure.
    static func captureDetail(_ error: ExportPDFCaptureError, product: ExportCommandProduct) -> String {
        switch error {
        case .oversizeAtomicBox:
            product == .print
                ? "A diagram, image, or formula is too tall to print (over 200 inches). " +
                "Shrink or split it, then try again."
                : "A diagram, image, or formula is taller than a PDF page can hold (200 inches). " +
                "Shrink or split it, then try again."
        case .breakCrossesPositionedContent:
            product == .print
                ? "An element with floating, sticky, or transformed styling sits where a page " +
                "break is needed, so the document can’t be split into printed pages safely. " +
                "Remove that styling, then try again."
                : "An element with floating, sticky, or transformed styling sits where a page " +
                "break is needed, so the PDF can’t be split into pages safely. " +
                "Remove that styling, then try again."
        case .webContentProcessTerminated, .invalidated:
            product == .print
                ? "The renderer stopped while preparing the document for printing. Try again."
                : "The renderer stopped while preparing the PDF. Try again."
        case .geometryUnstable:
            product == .print
                ? "The layout kept changing while preparing the document for printing. Try again."
                : "The layout kept changing while preparing the PDF. Try again."
        case .captureFailed, .emptyDocument:
            "The document couldn’t be rendered for export. Try again."
        }
    }

    /// The 64 MiB serialization limit named for the actual product.
    static func tooLargeDetail(for product: ExportCommandProduct) -> String {
        switch product {
        case .html:
            "The exported HTML exceeds the 64 MiB limit. Reduce the document’s images or content, then try again."
        case .pdf:
            "This document is too large to export as PDF (64 MiB limit). Reduce the document’s images or content, then try again."
        case .print:
            "This document is too large to print (64 MiB limit). Reduce the document’s images or content, then try again."
        }
    }
}
