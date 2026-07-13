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
    public static let defaultMaximumReportedSkippedFiles = 100
    public static let defaultMaximumProgressEvents = 100

    public let maximumFileSizeBytes: Int
    public let maximumMatchesPerFile: Int
    public let maximumMatchesPerQuery: Int
    public let maximumConcurrentReads: Int
    public let maximumIgnoreFileSizeBytes: Int
    public let maximumIgnoreFiles: Int
    public let maximumReportedSkippedFiles: Int
    public let maximumProgressEvents: Int

    public init(
        maximumFileSizeBytes: Int = WorkspaceSearchLimits.defaultMaximumFileSizeBytes,
        maximumMatchesPerFile: Int = WorkspaceSearchLimits.defaultMaximumMatchesPerFile,
        maximumMatchesPerQuery: Int = WorkspaceSearchLimits.defaultMaximumMatchesPerQuery,
        maximumConcurrentReads: Int = WorkspaceSearchLimits.defaultMaximumConcurrentReads,
        maximumIgnoreFileSizeBytes: Int = WorkspaceSearchLimits.defaultMaximumIgnoreFileSizeBytes,
        maximumIgnoreFiles: Int = WorkspaceSearchLimits.defaultMaximumIgnoreFiles,
        maximumReportedSkippedFiles: Int = WorkspaceSearchLimits.defaultMaximumReportedSkippedFiles,
        maximumProgressEvents: Int = WorkspaceSearchLimits.defaultMaximumProgressEvents
    ) {
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.maximumMatchesPerFile = maximumMatchesPerFile
        self.maximumMatchesPerQuery = maximumMatchesPerQuery
        self.maximumConcurrentReads = max(1, maximumConcurrentReads)
        self.maximumIgnoreFileSizeBytes = maximumIgnoreFileSizeBytes
        self.maximumIgnoreFiles = maximumIgnoreFiles
        self.maximumReportedSkippedFiles = max(0, maximumReportedSkippedFiles)
        self.maximumProgressEvents = max(1, maximumProgressEvents)
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
    public let dirtyOverlays: WorkspaceSearchOverlayCollection
    public let limits: WorkspaceSearchLimits
    let rootAuthority: WorkspaceFileSystemRootAuthority

    public init(
        rootURL: URL,
        rootAuthority: WorkspaceFileSystemRootAuthority? = nil,
        rootIdentity: String? = nil,
        snapshot: WorkspaceFileSnapshot,
        workspaceGeneration: UInt64,
        queryGeneration: UInt64,
        query: TextSearchQuery,
        dirtyOverlays: WorkspaceSearchOverlayCollection = .empty,
        limits: WorkspaceSearchLimits = .init()
    ) {
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        let rootAuthority = rootAuthority ?? WorkspaceFileSystemRootAuthority(
            rootURL: standardizedRoot
        )
        self.rootAuthority = rootAuthority
        self.rootIdentity = rootIdentity
            ?? rootAuthority.canonicalRootURL.path(percentEncoded: false)
        self.snapshot = snapshot
        self.workspaceGeneration = workspaceGeneration
        self.queryGeneration = queryGeneration
        self.query = query
        self.dirtyOverlays = dirtyOverlays
        self.limits = limits
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

/// Exact physical file searched beneath an immutable root authority.
///
/// Activation must use `location` together with `identity` rather than deriving a new
/// path authority from `relativePath`. The identity is sampled from the same descriptor
/// used for the production bounded read or overlay eligibility validation.
public struct WorkspaceSearchFileAuthority: Sendable, Equatable {
    public let location: WorkspaceFileSystemLocation
    public let identity: WorkspaceFileSystemIdentity

    public init(
        location: WorkspaceFileSystemLocation,
        identity: WorkspaceFileSystemIdentity
    ) {
        self.location = location
        self.identity = identity
    }
}

public struct WorkspaceSearchFileResult: Sendable, Equatable {
    public let relativePath: String
    public let contentFingerprint: WorkspaceSearchContentFingerprint
    public let matches: [TextSearchMatch]
    public let isTruncated: Bool
    public let fileAuthority: WorkspaceSearchFileAuthority?

    public init(
        relativePath: String,
        contentFingerprint: WorkspaceSearchContentFingerprint,
        matches: [TextSearchMatch],
        isTruncated: Bool,
        fileAuthority: WorkspaceSearchFileAuthority? = nil
    ) {
        self.relativePath = relativePath
        self.contentFingerprint = contentFingerprint
        self.matches = matches
        self.isTruncated = isTruncated
        self.fileAuthority = fileAuthority
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
    case unsupportedPhysicalFileKind
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
    public let maximumBufferedReadCount: Int
    public let maximumOutstandingReadCount: Int

    public init(
        diskReadCount: Int,
        diskReadByteCount: Int,
        maximumConcurrentReads: Int,
        maximumBufferedReadCount: Int,
        maximumOutstandingReadCount: Int
    ) {
        self.diskReadCount = diskReadCount
        self.diskReadByteCount = diskReadByteCount
        self.maximumConcurrentReads = maximumConcurrentReads
        self.maximumBufferedReadCount = maximumBufferedReadCount
        self.maximumOutstandingReadCount = maximumOutstandingReadCount
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
    public let omittedSkippedFileCount: Int
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
        omittedSkippedFileCount: Int,
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
        self.omittedSkippedFileCount = omittedSkippedFileCount
        self.readInstrumentation = readInstrumentation
    }

    public var hasPerFileTruncation: Bool {
        !truncatedFilePaths.isEmpty
    }

    public var isTruncated: Bool {
        hasPerFileTruncation || isGloballyTruncated
    }

    public var areSkippedFileDetailsTruncated: Bool {
        omittedSkippedFileCount > 0
    }
}

public enum WorkspaceSearchValidationError: Sendable, Equatable {
    case emptyQuery
    case newlineInQuery
    case overlongQuery(maximumUTF16Length: Int)
}

/// Typed terminal failure for an unexpected producer-level fault.
public enum WorkspaceSearchServiceFailure: Error, Sendable, Equatable {
    case unexpectedProducerFailure
}

/// Ordered events from a cancellable workspace-search request.
public enum WorkspaceSearchEvent: Sendable, Equatable {
    case fileResult(WorkspaceSearchContext, WorkspaceSearchFileResult)
    case skippedFile(WorkspaceSearchContext, WorkspaceSearchSkippedFile)
    case progress(WorkspaceSearchContext, WorkspaceSearchProgress)
    case completed(WorkspaceSearchContext, WorkspaceSearchSummary)
    case failed(WorkspaceSearchContext, WorkspaceSearchServiceFailure)
    case validationFailure(WorkspaceSearchContext, WorkspaceSearchValidationError)
}
