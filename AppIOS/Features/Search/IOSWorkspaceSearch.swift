import Foundation
import MarkdownCore
import WorkspaceCore
import WorkspaceKitIOS

enum IOSWorkspaceSearchReadError: Error, Equatable {
    case tooLarge
    case unsupportedEncoding
}

enum IOSWorkspaceSearchLimits {
    static let maximumFileBytes = 512 * 1024
    static let maximumMatchesPerFile = 200
    static let maximumMatchesPerQuery = 2000
    static let maximumFiles = 5000
}

struct IOSWorkspaceSearchOpenDocument: Equatable {
    let workspaceID: IOSWorkspaceIdentity
    let relativePath: String
    let text: String
}

struct IOSWorkspaceSearchEnvironment {
    var scope: IOSWorkspaceScope?
    var entries: [IOSWorkspaceEntry]
    var openDocument: IOSWorkspaceSearchOpenDocument?
    var read: @MainActor (IOSFileLocation) async throws -> String
}

struct IOSWorkspaceSearchHit: Identifiable, Equatable {
    let id: String
    let range: NSRange
    let line: Int
    let preview: String
    let previewMatchRange: NSRange
    let matchedText: String
}

struct IOSWorkspaceSearchSection: Identifiable {
    let id: String
    let relativePath: String
    let location: IOSFileLocation
    let hits: [IOSWorkspaceSearchHit]
    let truncated: Bool
}

enum IOSDocumentStatisticsPresentation {
    static func counts(_ statistics: TextStatistics) -> String {
        "\(statistics.lineCount) lines · \(statistics.wordCount) words · \(statistics.characterCount) characters"
    }

    static func accessibilitySummary(_ statistics: TextStatistics) -> String {
        "\(statistics.lineCount) lines, \(statistics.wordCount) words, \(statistics.characterCount) characters"
    }
}

struct IOSWorkspaceSearchProgress: Equatable {
    var matchCount = 0
    var fileCount = 0
    var searching = false
    var queryTruncated = false
    var matchLimit = IOSWorkspaceSearchLimits.maximumMatchesPerQuery
    var skippedLarge = 0
    var skippedEncoding = 0
    var skippedUnavailable = 0
    var skippedOther = 0
    var stoppedAfterFileLimit = false
    var folderChanged = false
}

enum IOSWorkspaceSearchStatus {
    static func describe(_ progress: IOSWorkspaceSearchProgress) -> String {
        let matchCount = progress.matchCount
        let fileCount = progress.fileCount
        let searching = progress.searching
        let queryTruncated = progress.queryTruncated
        let matchLimit = progress.matchLimit
        let skippedLarge = progress.skippedLarge
        let skippedEncoding = progress.skippedEncoding
        let skippedUnavailable = progress.skippedUnavailable
        let skippedOther = progress.skippedOther
        let stoppedAfterFileLimit = progress.stoppedAfterFileLimit
        let folderChanged = progress.folderChanged
        if folderChanged {
            return "The folder changed. Search again."
        }
        let base: String
        if searching, matchCount == 0 {
            base = "Searching…"
        } else if matchCount == 0 {
            base = "No matches"
        } else {
            let matches = matchCount == 1 ? "match" : "matches"
            let files = fileCount == 1 ? "file" : "files"
            if searching {
                base = "Searching… \(matchCount) \(matches) in \(fileCount) \(files) so far"
            } else {
                base = "\(matchCount) \(matches) in \(fileCount) \(files)"
            }
        }
        var notes: [String] = []
        if queryTruncated {
            notes.append("Showing the first \(matchLimit) matches")
        }
        if stoppedAfterFileLimit {
            notes.append("Stopped after \(IOSWorkspaceSearchLimits.maximumFiles) files")
        }
        if skippedLarge > 0 {
            notes.append(skippedLarge == 1 ? "1 file is too large" : "\(skippedLarge) files are too large")
        }
        if skippedEncoding > 0 {
            notes.append(skippedEncoding == 1
                ? "1 file is not UTF-8"
                : "\(skippedEncoding) files are not UTF-8")
        }
        if skippedUnavailable > 0 {
            notes.append(skippedUnavailable == 1
                ? "1 file is unavailable"
                : "\(skippedUnavailable) files are unavailable")
        }
        if skippedOther > 0 {
            notes.append(skippedOther == 1 ? "1 file could not be read" : "\(skippedOther) files could not be read")
        }
        guard !notes.isEmpty else { return base }
        return base + ". " + notes.joined(separator: ". ")
    }
}

enum IOSWorkspaceTextSearch {
    static func hits(
        in text: String,
        query: TextSearchQuery,
        fileLimit: Int,
        remaining: Int
    ) -> (hits: [IOSWorkspaceSearchHit], truncated: Bool) {
        let limit = min(max(fileLimit, 0), max(remaining, 0))
        guard limit > 0 else { return ([], remaining <= 0) }
        let found = TextSearchEngine.matches(in: text, query: query, limit: limit + 1)
        let truncated = found.count > limit
        let source = text as NSString
        let hits = found.prefix(limit).enumerated().compactMap { index, match -> IOSWorkspaceSearchHit? in
            guard NSMaxRange(match.range) <= source.length else { return nil }
            return IOSWorkspaceSearchHit(
                id: "\(index):\(match.range.location):\(match.range.length)",
                range: match.range,
                line: match.line,
                preview: match.preview,
                previewMatchRange: match.previewMatchRange,
                matchedText: source.substring(with: match.range)
            )
        }
        return (hits, truncated)
    }
}

private enum IOSWorkspaceSearchIndex {
    static func documents(
        in entries: [IOSWorkspaceEntry]
    ) -> (ready: [IOSWorkspaceEntry], unavailable: Int) {
        var ready: [IOSWorkspaceEntry] = []
        var unavailable = 0
        func walk(_ entries: [IOSWorkspaceEntry]) {
            for entry in entries {
                switch entry.kind {
                case .document:
                    switch entry.availability {
                    case .available:
                        ready.append(entry)
                    case .downloading, .offline, .unavailable:
                        unavailable += 1
                    case .removed:
                        break
                    }
                case .directory, .image, .other:
                    walk(entry.children)
                }
            }
        }
        walk(entries)
        ready.sort { $0.location.relativePath < $1.location.relativePath }
        return (ready, unavailable)
    }

    static func sameFile(_ lhs: IOSWorkspaceSearchOpenDocument, _ rhs: IOSFileLocation) -> Bool {
        lhs.workspaceID == rhs.workspaceID && lhs.relativePath.utf8.elementsEqual(rhs.relativePath.utf8)
    }
}

@MainActor
final class IOSWorkspaceSearchController: ObservableObject {
    @Published private(set) var queryText = ""
    @Published private(set) var caseSensitivity: TextSearchCaseSensitivity = .smart
    @Published private(set) var wholeWord = false
    @Published private(set) var sections: [IOSWorkspaceSearchSection] = []
    @Published private(set) var statusText = "Search Markdown files in this folder."
    @Published private(set) var isSearching = false

    var hasQuery: Bool {
        !queryText.isEmpty
    }

    private let maximumMatchesPerFile: Int
    private let maximumMatchesPerQuery: Int
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        maximumMatchesPerFile: Int = IOSWorkspaceSearchLimits.maximumMatchesPerFile,
        maximumMatchesPerQuery: Int = IOSWorkspaceSearchLimits.maximumMatchesPerQuery
    ) {
        self.maximumMatchesPerFile = maximumMatchesPerFile
        self.maximumMatchesPerQuery = maximumMatchesPerQuery
    }

    func scheduleSearch(
        query: String? = nil,
        caseSensitivity: TextSearchCaseSensitivity? = nil,
        wholeWord: Bool? = nil,
        environment: IOSWorkspaceSearchEnvironment,
        immediate: Bool = false
    ) {
        if let query, query != queryText { queryText = query }
        if let caseSensitivity, caseSensitivity != self.caseSensitivity {
            self.caseSensitivity = caseSensitivity
        }
        if let wholeWord, wholeWord != self.wholeWord { self.wholeWord = wholeWord }
        task?.cancel()
        generation &+= 1
        let token = generation
        let textQuery = TextSearchQuery(
            pattern: queryText,
            caseSensitivity: self.caseSensitivity,
            wholeWord: self.wholeWord
        )
        if textQuery.pattern.isEmpty {
            sections = []
            isSearching = false
            statusText = environment.scope == .directory
                ? "Search Markdown files in this folder."
                : "Open a folder to search across files."
            return
        }
        if let rejection = rejection(for: textQuery) {
            sections = []
            isSearching = false
            statusText = rejection
            return
        }
        guard environment.scope == .directory else {
            sections = []
            isSearching = false
            statusText = "Open a folder to search across files."
            return
        }
        isSearching = true
        if sections.isEmpty { statusText = "Searching…" }
        task = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled, let self, generation == token else { return }
            await run(token: token, query: textQuery, environment: environment)
        }
    }

    func searchNow(
        query: String,
        environment: IOSWorkspaceSearchEnvironment,
        caseSensitivity: TextSearchCaseSensitivity? = nil,
        wholeWord: Bool = false
    ) async {
        scheduleSearch(
            query: query,
            caseSensitivity: caseSensitivity,
            wholeWord: wholeWord,
            environment: environment,
            immediate: true
        )
        await task?.value
    }

    func report(_ message: String) {
        statusText = message
    }

    func cancel() {
        task?.cancel()
        generation &+= 1
        if isSearching { isSearching = false }
    }

    private func rejection(for query: TextSearchQuery) -> String? {
        if query.pattern.utf16.count > TextSearchEngine.maximumPatternUTF16Length {
            return "The search text is too long."
        }
        if query.pattern.contains(where: \.isNewline) {
            return "The search text cannot contain a line break."
        }
        return nil
    }

    private func run(
        token: UInt64,
        query: TextSearchQuery,
        environment: IOSWorkspaceSearchEnvironment
    ) async {
        let classified = IOSWorkspaceSearchIndex.documents(in: environment.entries)
        var ready = classified.ready
        let stoppedAfterFileLimit = ready.count > IOSWorkspaceSearchLimits.maximumFiles
        if stoppedAfterFileLimit {
            ready = Array(ready.prefix(IOSWorkspaceSearchLimits.maximumFiles))
        }
        var produced: [IOSWorkspaceSearchSection] = []
        var matchCount = 0
        var skippedLarge = 0
        var skippedEncoding = 0
        var skippedUnavailable = classified.unavailable
        var skippedOther = 0
        var queryTruncated = false
        var folderChanged = false
        var seenPaths: [String: Int] = [:]

        for entry in ready {
            if Task.isCancelled || generation != token { return }
            if matchCount >= maximumMatchesPerQuery {
                queryTruncated = true
                break
            }
            switch await load(entry, environment: environment, token: token) {
            case .cancelled:
                return
            case .folderChanged:
                folderChanged = true
            case .tooLarge:
                skippedLarge += 1
            case .unsupportedEncoding:
                skippedEncoding += 1
            case .unavailable:
                skippedUnavailable += 1
            case .failed:
                skippedOther += 1
            case let .text(text):
                let remaining = maximumMatchesPerQuery - matchCount
                let found = IOSWorkspaceTextSearch.hits(
                    in: text,
                    query: query,
                    fileLimit: maximumMatchesPerFile,
                    remaining: remaining
                )
                matchCount += found.hits.count
                if found.truncated, remaining <= maximumMatchesPerFile {
                    queryTruncated = true
                }
                if !found.hits.isEmpty {
                    let path = entry.location.relativePath.isEmpty ? "Untitled" : entry.location.relativePath
                    let ordinal = seenPaths[path, default: 0]
                    seenPaths[path] = ordinal + 1
                    let identity = ordinal == 0 ? path : "\(path)#\(ordinal)"
                    let hits = found.hits.enumerated().map { index, hit in
                        IOSWorkspaceSearchHit(
                            id: "\(identity)#\(index)#\(hit.range.location)",
                            range: hit.range,
                            line: hit.line,
                            preview: hit.preview,
                            previewMatchRange: hit.previewMatchRange,
                            matchedText: hit.matchedText
                        )
                    }
                    produced.append(IOSWorkspaceSearchSection(
                        id: identity,
                        relativePath: path,
                        location: entry.location,
                        hits: hits,
                        truncated: found.truncated && matchCount < maximumMatchesPerQuery
                    ))
                }
            }
            publish(token: token, sections: produced, progress: IOSWorkspaceSearchProgress(
                matchCount: matchCount,
                searching: true,
                queryTruncated: queryTruncated,
                matchLimit: maximumMatchesPerQuery,
                skippedLarge: skippedLarge,
                skippedEncoding: skippedEncoding,
                skippedUnavailable: skippedUnavailable,
                skippedOther: skippedOther,
                stoppedAfterFileLimit: stoppedAfterFileLimit,
                folderChanged: folderChanged
            ))
            if folderChanged || queryTruncated { break }
        }
        publish(token: token, sections: produced, progress: IOSWorkspaceSearchProgress(
            matchCount: matchCount,
            searching: false,
            queryTruncated: queryTruncated,
            matchLimit: maximumMatchesPerQuery,
            skippedLarge: skippedLarge,
            skippedEncoding: skippedEncoding,
            skippedUnavailable: skippedUnavailable,
            skippedOther: skippedOther,
            stoppedAfterFileLimit: stoppedAfterFileLimit,
            folderChanged: folderChanged
        ))
    }

    private func publish(
        token: UInt64,
        sections: [IOSWorkspaceSearchSection],
        progress: IOSWorkspaceSearchProgress
    ) {
        guard generation == token, !Task.isCancelled else { return }
        var progress = progress
        progress.fileCount = sections.count
        self.sections = sections
        isSearching = progress.searching
        statusText = IOSWorkspaceSearchStatus.describe(progress)
    }

    private enum Load {
        case text(String)
        case tooLarge
        case unsupportedEncoding
        case unavailable
        case failed
        case folderChanged
        case cancelled
    }

    private func load(
        _ entry: IOSWorkspaceEntry,
        environment: IOSWorkspaceSearchEnvironment,
        token: UInt64
    ) async -> Load {
        if let open = environment.openDocument, IOSWorkspaceSearchIndex.sameFile(open, entry.location) {
            return .text(open.text)
        }
        do {
            let text = try await environment.read(entry.location)
            if Task.isCancelled || generation != token { return .cancelled }
            return .text(text)
        } catch is CancellationError {
            return .cancelled
        } catch IOSWorkspaceSearchReadError.tooLarge {
            return .tooLarge
        } catch IOSWorkspaceSearchReadError.unsupportedEncoding {
            return .unsupportedEncoding
        } catch let failure as IOSWorkspaceFailure {
            switch failure {
            case .tooLarge:
                return .tooLarge
            case .downloading, .offline, .unavailable, .notFound:
                return .unavailable
            case .grantChanged, .outsideGrant:
                return .folderChanged
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }
}
