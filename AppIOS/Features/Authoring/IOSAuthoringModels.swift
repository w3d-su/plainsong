import EditorKitIOS
import Foundation
import MarkdownCore

struct IOSLinkDraft: Identifiable {
    let id = UUID()
    let snapshot: IOSSourceEditorSnapshot
    let planned: MarkdownEditResult
    var label = ""
    var url = ""
    var collectsLabel: Bool
}

struct IOSFrontmatterModel {
    var acceptedText = ""
    var capture: IOSSourceEditorSnapshot?
    var needsRecapture = false
    var drafts: [String: FrontmatterValue] = [:]
    var acceptedParse = FrontmatterParseResult(block: nil)
    var liveParse = FrontmatterParseResult(block: nil)
}

enum IOSFindQueryClassification: Equatable {
    case empty
    case invalid
    case searchable
}

enum IOSFindStatus: Equatable {
    case empty
    case invalid
    case searching
    case noResults
    case matches
}

struct IOSFindModel {
    var isPresented = false
    var queryText = ""
    var caseSensitivity: TextSearchCaseSensitivity = .smart
    var wholeWord = false
    var replacement = ""
    var status: IOSFindStatus = .empty
    var counterText = ""
    var message = ""
    var session: EditorFindSession?
    var queryGeneration: UInt64 = 0
    var pendingSteps = 0
    var editorSelection = NSRange(location: 0, length: 0)
    var hasEditorSelection = false
}

enum IOSFindQuery {
    static let invalidMessage = "Find text can't contain a line break or more than 256 characters."
    static let noResultsMessage = "No results."

    static func classify(_ pattern: String) -> IOSFindQueryClassification {
        if pattern.isEmpty {
            return .empty
        }
        let tooLong = pattern.utf16.count > TextSearchEngine.maximumPatternUTF16Length
        if pattern.contains(where: \.isNewline) || tooLong {
            return .invalid
        }
        return .searchable
    }

    static func counter(for session: EditorFindSession) -> String {
        let total = session.isTruncated ? "10,000+" : "\(session.total)"
        guard session.total > 0 else { return "" }
        let ordinal = session.currentOrdinal ?? 0
        return "\(ordinal) / \(total)"
    }
}
