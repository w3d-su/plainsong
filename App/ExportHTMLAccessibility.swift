import Foundation

enum ExportHTMLAccessibility {
    static let command = "export-html-command"
    static let savePanel = "export-html-save-panel"
    static let progress = "export-html-progress"
    static let cancel = "export-html-cancel"
    static let dismiss = "export-html-dismiss"
    static let reveal = "export-html-reveal"

    static func notice(_ group: ExportHTMLNoticeGroup) -> String {
        "export-html-notice-\(group.rawValue)"
    }

    static func progressLabel(fileName: String) -> String {
        "Exporting \(fileName) as HTML. Cancel to stop the export."
    }
}
