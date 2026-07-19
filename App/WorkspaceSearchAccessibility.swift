import Foundation

// MARK: - Stable accessibility identifiers and labels (WS3C PR C)

/// Accessibility identifiers and label builders for workspace search chrome.
///
/// Identifiers are ASCII and path-byte based so NFC/NFD relatives stay distinct.
enum WorkspaceSearchAccessibility {
    /// Must stay identical to `WorkspaceSearchFieldFocus.accessibilityIdentifier`.
    static let queryField = "plainsong.workspaceSearch.queryField"
    static let modePicker = "plainsong.workspaceSearch.mode"
    static let matchCase = "plainsong.workspaceSearch.matchCase"
    static let wholeWord = "plainsong.workspaceSearch.wholeWord"
    static let resultsList = "plainsong.workspaceSearch.results"
    static let status = "plainsong.workspaceSearch.status"
    static let banners = "plainsong.workspaceSearch.banners"
    static let retry = "plainsong.workspaceSearch.retry"

    static func banner(_ banner: WorkspaceSearchBanner) -> String {
        "plainsong.workspaceSearch.banner.\(banner.id)"
    }

    static func section(_ sectionID: WorkspaceSearchResultFileSectionID) -> String {
        "plainsong.workspaceSearch.section."
            + pathToken(sectionID.pathUTF8)
            + ".g\(sectionID.queryGeneration)"
    }

    static func row(_ rowID: WorkspaceSearchResultRowID) -> String {
        "plainsong.workspaceSearch.row."
            + pathToken(rowID.pathUTF8)
            + ".g\(rowID.queryGeneration)"
            + ".l\(rowID.matchLocation)"
            + ".n\(rowID.matchLength)"
            + ".o\(rowID.ordinal)"
    }

    /// VoiceOver label: relative path, line number, and snippet (required contract).
    static func rowLabel(
        relativePath: String,
        lineNumber: Int,
        snippet: String
    ) -> String {
        "\(relativePath), line \(lineNumber), \(snippet)"
    }

    /// Extra spoken value for availability (selected is exposed via traits separately).
    static func rowValue(canActivate: Bool) -> String {
        canActivate ? "Available" : "Unavailable"
    }

    static func statusLabel(_ status: WorkspaceSearchStatusPresentation) -> String? {
        switch status {
        case .hidden:
            nil
        case let .prompt(message):
            message
        case .waiting:
            "Waiting to search"
        case let .searching(completed, total):
            if total > 0 {
                "Searching \(completed) of \(total)"
            } else {
                "Searching"
            }
        case .noResults:
            "No Results"
        case let .validationFailure(message):
            "Search validation error: \(message)"
        case let .serviceFailure(message):
            "Search error: \(message)"
        }
    }

    static func bannerLabel(_ banner: WorkspaceSearchBanner) -> String {
        switch banner {
        case let .skipped(count, detailLines, omitted):
            var text = "Skipped \(count) file\(count == 1 ? "" : "s")"
            if omitted > 0 {
                text += ", \(omitted) detail\(omitted == 1 ? "" : "s") omitted"
            }
            if !detailLines.isEmpty {
                text += ". " + detailLines.prefix(3).joined(separator: "; ")
            }
            return text
        case .globalTruncation:
            return "Results truncated because the global match limit was reached"
        case let .perFileTruncation(pathCount):
            return "Results truncated in \(pathCount) file\(pathCount == 1 ? "" : "s")"
        }
    }

    static func sectionLabel(
        relativePath: String,
        matchCount: Int,
        isTruncated: Bool,
        canActivate: Bool
    ) -> String {
        var parts = [
            relativePath,
            "\(matchCount) match\(matchCount == 1 ? "" : "es")",
        ]
        if isTruncated {
            parts.append("truncated")
        }
        if !canActivate {
            parts.append("unavailable")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Private

    private static func pathToken(_ pathUTF8: Data) -> String {
        pathUTF8.map { String(format: "%02x", $0) }.joined()
    }
}
