import Foundation
import MarkdownCore

/// Bounded resource settings for one workspace-search request.
public struct WorkspaceSearchLimits: Sendable, Equatable {
    public static let defaultMaximumFileSizeBytes = 512 * 1024
    public static let defaultMaximumMatchesPerFile = 500
    public static let defaultMaximumMatchesPerQuery = 10000
    public static let defaultMaximumConcurrentReads = 4
    public static let defaultMaximumIgnoreFileSizeBytes = 64 * 1024
    public static let defaultMaximumIgnoreFiles = 128

    public let maximumFileSizeBytes: Int
    public let maximumMatchesPerFile: Int
    public let maximumMatchesPerQuery: Int
    public let maximumConcurrentReads: Int
    public let maximumIgnoreFileSizeBytes: Int
    public let maximumIgnoreFiles: Int

    public init(
        maximumFileSizeBytes: Int = WorkspaceSearchLimits.defaultMaximumFileSizeBytes,
        maximumMatchesPerFile: Int = WorkspaceSearchLimits.defaultMaximumMatchesPerFile,
        maximumMatchesPerQuery: Int = WorkspaceSearchLimits.defaultMaximumMatchesPerQuery,
        maximumConcurrentReads: Int = WorkspaceSearchLimits.defaultMaximumConcurrentReads,
        maximumIgnoreFileSizeBytes: Int = WorkspaceSearchLimits.defaultMaximumIgnoreFileSizeBytes,
        maximumIgnoreFiles: Int = WorkspaceSearchLimits.defaultMaximumIgnoreFiles
    ) {
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.maximumMatchesPerFile = maximumMatchesPerFile
        self.maximumMatchesPerQuery = maximumMatchesPerQuery
        self.maximumConcurrentReads = maximumConcurrentReads
        self.maximumIgnoreFileSizeBytes = maximumIgnoreFileSizeBytes
        self.maximumIgnoreFiles = maximumIgnoreFiles
    }
}

/// Immutable unsaved text that takes precedence over on-disk workspace content.
public struct WorkspaceSearchOverlay: Sendable, Equatable {
    public let relativePath: String
    public let text: String
    /// Caller-provided document version or stable content fingerprint.
    public let sourceVersion: String

    public init(relativePath: String, text: String, sourceVersion: String) {
        self.relativePath = Self.preservedPath(relativePath)
        self.text = text
        self.sourceVersion = sourceVersion
    }

    private static func preservedPath(_ path: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        return path
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .joined(separator: "/")
    }
}

/// Immutable input for one workspace search.
public struct WorkspaceSearchRequest: Sendable, Equatable {
    public let rootURL: URL
    public let rootIdentity: String
    public let snapshot: WorkspaceFileSnapshot
    public let workspaceGeneration: UInt64
    public let queryGeneration: UInt64
    public let query: TextSearchQuery
    public let dirtyOverlays: [String: WorkspaceSearchOverlay]
    public let limits: WorkspaceSearchLimits

    public init(
        rootURL: URL,
        rootIdentity: String? = nil,
        snapshot: WorkspaceFileSnapshot,
        workspaceGeneration: UInt64,
        queryGeneration: UInt64,
        query: TextSearchQuery,
        dirtyOverlays: [String: WorkspaceSearchOverlay] = [:],
        limits: WorkspaceSearchLimits = .init()
    ) {
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        self.rootIdentity = rootIdentity
            ?? standardizedRoot.resolvingSymlinksInPath().path(percentEncoded: false)
        self.snapshot = snapshot
        self.workspaceGeneration = workspaceGeneration
        self.queryGeneration = queryGeneration
        self.query = query
        self.dirtyOverlays = Self.normalizedOverlays(dirtyOverlays)
        self.limits = limits
    }

    private static func normalizedOverlays(
        _ overlays: [String: WorkspaceSearchOverlay]
    ) -> [String: WorkspaceSearchOverlay] {
        var result: [String: WorkspaceSearchOverlay] = [:]
        for overlay in overlays.values {
            let key = (try? WorkspaceRootContainment.normalizedRelativePath(overlay.relativePath))
                ?? overlay.relativePath
            result[key] = overlay
        }
        return result
    }
}

/// Stable identity attached to every event from a search request.
public struct WorkspaceSearchContext: Sendable, Equatable {
    public let rootIdentity: String
    public let workspaceGeneration: UInt64
    public let queryGeneration: UInt64

    public init(rootIdentity: String, workspaceGeneration: UInt64, queryGeneration: UInt64) {
        self.rootIdentity = rootIdentity
        self.workspaceGeneration = workspaceGeneration
        self.queryGeneration = queryGeneration
    }
}

public struct WorkspaceSearchFileResult: Sendable, Equatable {
    public let relativePath: String
    public let sourceVersion: String
    public let matches: [TextSearchMatch]
    public let isTruncated: Bool

    public init(
        relativePath: String,
        sourceVersion: String,
        matches: [TextSearchMatch],
        isTruncated: Bool
    ) {
        self.relativePath = relativePath
        self.sourceVersion = sourceVersion
        self.matches = matches
        self.isTruncated = isTruncated
    }
}

public enum WorkspaceSearchSkipReason: Sendable, Equatable {
    case disappeared
    case unreadable
    case invalidUTF8
    case oversized(byteCount: Int)
    case emptyPath
    case absolutePath
    case pathTraversal
    case symlinkEscape
}

/// A nonfatal file-level failure. Search continues after every skipped file.
public struct WorkspaceSearchSkippedFile: Sendable, Equatable {
    public let relativePath: String
    public let reason: WorkspaceSearchSkipReason

    public init(relativePath: String, reason: WorkspaceSearchSkipReason) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

public struct WorkspaceSearchProgress: Sendable, Equatable {
    public let completedFileCount: Int
    public let candidateFileCount: Int

    public init(completedFileCount: Int, candidateFileCount: Int) {
        self.completedFileCount = completedFileCount
        self.candidateFileCount = candidateFileCount
    }
}

/// Resource observations from a completed request, useful for deterministic tests and tuning.
public struct WorkspaceSearchReadInstrumentation: Sendable, Equatable {
    public let diskReadCount: Int
    public let diskReadByteCount: Int
    public let maximumConcurrentReads: Int

    public init(diskReadCount: Int, diskReadByteCount: Int, maximumConcurrentReads: Int) {
        self.diskReadCount = diskReadCount
        self.diskReadByteCount = diskReadByteCount
        self.maximumConcurrentReads = maximumConcurrentReads
    }
}

public struct WorkspaceSearchSummary: Sendable, Equatable {
    public let candidateFileCount: Int
    public let searchedFileCount: Int
    public let skippedFileCount: Int
    public let ignoredFileCount: Int
    public let totalEmittedMatchCount: Int
    public let truncatedFilePaths: [String]
    public let isGloballyTruncated: Bool
    public let skippedFiles: [WorkspaceSearchSkippedFile]
    public let readInstrumentation: WorkspaceSearchReadInstrumentation

    public init(
        candidateFileCount: Int,
        searchedFileCount: Int,
        skippedFileCount: Int,
        ignoredFileCount: Int,
        totalEmittedMatchCount: Int,
        truncatedFilePaths: [String],
        isGloballyTruncated: Bool,
        skippedFiles: [WorkspaceSearchSkippedFile],
        readInstrumentation: WorkspaceSearchReadInstrumentation
    ) {
        self.candidateFileCount = candidateFileCount
        self.searchedFileCount = searchedFileCount
        self.skippedFileCount = skippedFileCount
        self.ignoredFileCount = ignoredFileCount
        self.totalEmittedMatchCount = totalEmittedMatchCount
        self.truncatedFilePaths = truncatedFilePaths
        self.isGloballyTruncated = isGloballyTruncated
        self.skippedFiles = skippedFiles
        self.readInstrumentation = readInstrumentation
    }

    public var hasPerFileTruncation: Bool {
        !truncatedFilePaths.isEmpty
    }

    public var isTruncated: Bool {
        hasPerFileTruncation || isGloballyTruncated
    }
}

public enum WorkspaceSearchValidationError: Sendable, Equatable {
    case emptyQuery
    case newlineInQuery
    case overlongQuery(maximumUTF16Length: Int)
}

/// Ordered events from a cancellable workspace-search request.
public enum WorkspaceSearchEvent: Sendable, Equatable {
    case fileResult(WorkspaceSearchContext, WorkspaceSearchFileResult)
    case skippedFile(WorkspaceSearchContext, WorkspaceSearchSkippedFile)
    case progress(WorkspaceSearchContext, WorkspaceSearchProgress)
    case completed(WorkspaceSearchContext, WorkspaceSearchSummary)
    case validationFailure(WorkspaceSearchContext, WorkspaceSearchValidationError)
}
