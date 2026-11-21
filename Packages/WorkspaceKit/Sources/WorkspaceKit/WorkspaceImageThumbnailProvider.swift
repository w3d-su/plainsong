import Foundation
import MarkdownCore

/// Async workspace-scoped thumbnail loader for Markdown image sources.
///
/// Resolves document-relative paths, evaluates `MarkdownImageThumbnailPolicy`, and returns a
/// downsampled PNG bitmap. All file I/O runs under security-scoped root access; remote /
/// `data:` / `file:` sources never reach disk. The actor owns only the cache and the in-flight
/// table; the file read and the ImageIO decode run in a nonisolated function, so one large
/// image does not hold up cache hits or other loads.
public actor WorkspaceImageThumbnailProvider: WorkspaceImageThumbnailLoading {
    public static let defaultMaxPixelSize = 600
    public static let defaultCacheByteBudget = 32 * 1024 * 1024

    private let defaultMaxPixelSize: Int
    private var cache: WorkspaceImageThumbnailCache
    private var inFlight: [WorkspaceImageThumbnailCache.Key: Task<WorkspaceImageThumbnailOutcome, Never>] = [:]
    private let hooks: Hooks

    /// Test seams for the off-actor read and decode.
    struct Hooks: Sendable {
        static let production = Hooks()

        /// Runs after the containment and policy checks, immediately before the anchored read.
        var willReadSource: (@Sendable () -> Void)?
        var decode: @Sendable (Data, Int) throws -> WorkspaceImageThumbnailDecodeResult = {
            try WorkspaceImageThumbnailDecoder.decodePNGThumbnail(from: $0, maxPixelSize: $1)
        }
    }

    public init(
        defaultMaxPixelSize: Int = WorkspaceImageThumbnailProvider.defaultMaxPixelSize,
        cacheByteBudget: Int = WorkspaceImageThumbnailProvider.defaultCacheByteBudget
    ) {
        self.init(
            defaultMaxPixelSize: defaultMaxPixelSize,
            cacheByteBudget: cacheByteBudget,
            hooks: .production
        )
    }

    init(
        defaultMaxPixelSize: Int = WorkspaceImageThumbnailProvider.defaultMaxPixelSize,
        cacheByteBudget: Int = WorkspaceImageThumbnailProvider.defaultCacheByteBudget,
        hooks: Hooks
    ) {
        precondition(defaultMaxPixelSize > 0)
        precondition(cacheByteBudget > 0)
        self.hooks = hooks
        self.defaultMaxPixelSize = defaultMaxPixelSize
        cache = WorkspaceImageThumbnailCache(byteBudget: cacheByteBudget)
    }

    public func loadThumbnail(
        rootURL: URL,
        documentDirectoryRelativePath: String,
        source: String,
        maxPixelSize: Int
    ) async -> WorkspaceImageThumbnailOutcome {
        let pixelBound = maxPixelSize > 0 ? maxPixelSize : defaultMaxPixelSize
        return await load(
            rootURL: rootURL,
            documentDirectoryRelativePath: documentDirectoryRelativePath,
            source: source,
            maxPixelSize: pixelBound,
            hasDirectoryScope: true
        )
    }

    /// Loads a thumbnail when the open workspace may lack directory scope (single-file mode).
    public func load(
        rootURL: URL?,
        documentDirectoryRelativePath: String,
        source: String,
        maxPixelSize: Int = WorkspaceImageThumbnailProvider.defaultMaxPixelSize,
        hasDirectoryScope: Bool
    ) async -> WorkspaceImageThumbnailOutcome {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .stayRaw(.emptySource)
        }

        // Reject scheme-bearing sources before any path resolution or file I/O.
        let probe = MarkdownImageWorkspaceSource(
            source: trimmed,
            resolvedWorkspaceRelativePath: nil,
            fileByteCount: nil,
            isInsideWorkspaceRoot: false,
            hasDirectoryScope: hasDirectoryScope
        )
        let earlyEligibility = MarkdownImageThumbnailPolicy.eligibility(for: probe)
        if case let .stayRaw(reason) = earlyEligibility {
            switch reason {
            case .remoteHTTPSource, .dataSource, .fileSource, .unsupportedSourceScheme, .emptySource:
                return .stayRaw(reason)
            case .noDirectoryScope:
                return .stayRaw(.noDirectoryScope)
            default:
                break
            }
        }
        if !hasDirectoryScope {
            return .stayRaw(.noDirectoryScope)
        }
        guard let rootURL else {
            return .stayRaw(.noDirectoryScope)
        }

        let pixelBound = maxPixelSize > 0 ? maxPixelSize : defaultMaxPixelSize
        let access = SecurityScopedAccess.startAccessing(rootURL)
        defer { access.stop() }
        return await loadUnderSecurityScope(
            rootURL: rootURL,
            documentDirectoryRelativePath: documentDirectoryRelativePath,
            source: trimmed,
            maxPixelSize: pixelBound
        )
    }

    public func cacheStats() -> WorkspaceImageThumbnailCacheStats {
        cache.snapshotStats
    }

    // MARK: - Internals

    private func loadUnderSecurityScope(
        rootURL: URL,
        documentDirectoryRelativePath: String,
        source: String,
        maxPixelSize: Int
    ) async -> WorkspaceImageThumbnailOutcome {
        let resolved: (fileURL: URL, workspaceRelativePath: String)
        do {
            resolved = try WorkspaceRootContainment.containedURL(
                rootURL: rootURL,
                baseDirectoryRelativePath: documentDirectoryRelativePath,
                sourcePath: source
            )
        } catch WorkspaceRootContainmentError.absolutePath {
            return .stayRaw(.outsideWorkspace)
        } catch WorkspaceRootContainmentError.traversal {
            return .stayRaw(.outsideWorkspace)
        } catch WorkspaceRootContainmentError.symlinkEscape {
            return .stayRaw(.outsideWorkspace)
        } catch WorkspaceRootContainmentError.fileOutsideRoot {
            return .stayRaw(.outsideWorkspace)
        } catch WorkspaceRootContainmentError.emptyRelativePath {
            return .stayRaw(.emptySource)
        } catch {
            return .stayRaw(.unresolvedWorkspacePath)
        }

        // Only accept URLs we just resolved ourselves inside the root.
        guard WorkspaceRootContainment.isContained(resolved.fileURL, in: rootURL) else {
            return .stayRaw(.outsideWorkspace)
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try resolved.fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
        } catch {
            return .failed(.missingFile)
        }

        guard resourceValues.isRegularFile == true else {
            return .failed(.missingFile)
        }
        guard let fileSize = resourceValues.fileSize.map(Int64.init) else {
            let workspaceSource = MarkdownImageWorkspaceSource(
                source: source,
                resolvedWorkspaceRelativePath: resolved.workspaceRelativePath,
                fileByteCount: nil,
                isInsideWorkspaceRoot: true,
                hasDirectoryScope: true
            )
            if case let .stayRaw(reason) = MarkdownImageThumbnailPolicy.eligibility(for: workspaceSource) {
                return .stayRaw(reason)
            }
            return .stayRaw(.missingFileSize)
        }
        let modificationDate = resourceValues.contentModificationDate ?? .distantPast

        let workspaceSource = MarkdownImageWorkspaceSource(
            source: source,
            resolvedWorkspaceRelativePath: resolved.workspaceRelativePath,
            fileByteCount: fileSize,
            isInsideWorkspaceRoot: true,
            hasDirectoryScope: true
        )
        switch MarkdownImageThumbnailPolicy.eligibility(for: workspaceSource) {
        case let .stayRaw(reason):
            return .stayRaw(reason)
        case .thumbnailEligible:
            break
        }

        let cacheKey = WorkspaceImageThumbnailCache.Key(
            resolvedRootPath: WorkspaceRootContainment.resolvedRootURL(rootURL)
                .path(percentEncoded: false),
            resolvedWorkspaceRelativePath: resolved.workspaceRelativePath,
            contentModificationTime: modificationDate.timeIntervalSinceReferenceDate,
            maxPixelSize: maxPixelSize
        )

        if let cached = cache.lookup(cacheKey) {
            return .ready(cached)
        }

        if let existing = inFlight[cacheKey] {
            cache.recordCoalescedLoad()
            return await existing.value
        }

        cache.recordMiss()
        let request = DecodeRequest(
            rootURL: rootURL,
            workspaceRelativePath: resolved.workspaceRelativePath,
            modificationDate: modificationDate,
            maxPixelSize: maxPixelSize
        )
        let task = Task { [hooks] in
            let outcome = await Self.readAndDecode(request, hooks: hooks)
            return await self.finishDecode(outcome, cacheKey: cacheKey)
        }
        inFlight[cacheKey] = task
        let outcome = await task.value
        inFlight[cacheKey] = nil
        return outcome
    }

    private func finishDecode(
        _ outcome: WorkspaceImageThumbnailOutcome,
        cacheKey: WorkspaceImageThumbnailCache.Key
    ) -> WorkspaceImageThumbnailOutcome {
        if case let .ready(thumbnail) = outcome {
            cache.insert(thumbnail, for: cacheKey)
        }
        return outcome
    }
}

private extension WorkspaceImageThumbnailProvider {
    struct DecodeRequest: Sendable {
        let rootURL: URL
        let workspaceRelativePath: String
        let modificationDate: Date
        let maxPixelSize: Int
    }

    /// Reads the image through a root-anchored, no-follow descriptor walk and decodes those
    /// bytes. Nonisolated, so it runs on the global executor rather than on the provider actor.
    ///
    /// The path was resolved and contained a moment ago, but a path is not a file: an entry
    /// swapped for a symlink since then is refused here instead of being followed by ImageIO.
    nonisolated static func readAndDecode(
        _ request: DecodeRequest,
        hooks: Hooks
    ) async -> WorkspaceImageThumbnailOutcome {
        hooks.willReadSource?()
        let maximumByteCount = Int(MarkdownImageAssetPolicy.maximumFileSizeBytes)
        let read: WorkspaceAnchoredFileSystem.ReadResult
        do {
            let location = try WorkspaceFileSystemLocation(
                rootURL: WorkspaceRootContainment.resolvedRootURL(request.rootURL),
                relativePath: request.workspaceRelativePath,
                securityScopedURL: request.rootURL
            )
            read = try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
                // One byte past the cap tells a file that grew after the size check from one
                // that fits, without reading an unbounded file into memory.
                try WorkspaceAnchoredFileSystem.read(location, maximumByteCount: maximumByteCount + 1)
            }
        } catch WorkspaceAnchoredFileSystemError.missing {
            return .failed(.missingFile)
        } catch {
            return .failed(.unreadableFile)
        }
        guard read.data.count <= maximumByteCount else {
            return .stayRaw(.fileTooLarge(
                actualBytes: read.metadata.byteCount,
                maximumBytes: MarkdownImageAssetPolicy.maximumFileSizeBytes
            ))
        }

        do {
            let decoded = try hooks.decode(read.data, request.maxPixelSize)
            return .ready(WorkspaceImageThumbnail(
                pngData: decoded.pngData,
                pixelWidth: decoded.width,
                pixelHeight: decoded.height,
                resolvedWorkspaceRelativePath: request.workspaceRelativePath,
                contentModificationDate: request.modificationDate,
                sourceByteCount: Int64(read.data.count),
                decodedByteCost: decoded.decodedByteCost
            ))
        } catch let failure as WorkspaceImageThumbnailFailure {
            return .failed(failure)
        } catch {
            return .failed(.decodeFailed)
        }
    }
}
