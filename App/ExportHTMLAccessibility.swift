import Foundation

enum ExportHTMLAccessibility {
    static let command = "export-html-command"
    /// NSSavePanel exposes the system identifier even after setAccessibilityIdentifier.
    static let savePanel = "save-panel"
    static let progress = "export-html-progress"
    static let cancel = "export-html-cancel"
    static let dismiss = "export-html-dismiss"
    static let reveal = "export-html-reveal"

    static func notice(_ group: ExportHTMLNoticeGroup) -> String {
        "export-html-notice-\(group.rawValue)"
    }

    static func progressLabel(fileName: String, product: ExportCommandProduct = .html) -> String {
        switch product {
        case .html:
            "Exporting \(fileName) as HTML. Cancel to stop the export."
        case .pdf:
            "Exporting \(fileName) as PDF. Cancel to stop the export."
        case .print:
            "Printing \(fileName). Cancel to stop printing."
        }
    }
}

enum ExportPDFAccessibility {
    static let command = "export-pdf-command"
    static let printCommand = "export-print-command"
}
