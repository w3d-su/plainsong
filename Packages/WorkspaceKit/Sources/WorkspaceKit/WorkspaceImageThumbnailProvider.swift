import Foundation
import MarkdownCore

/// Async workspace-scoped thumbnail loader for Markdown image sources.
///
/// Resolves document-relative paths, evaluates `MarkdownImageThumbnailPolicy`, and returns a
/// downsampled PNG bitmap. All file I/O runs under security-scoped root access; remote /
/// `data:` / `file:` sources never reach disk. Decode and cache work stay off the main actor.
public actor WorkspaceImageThumbnailProvider: WorkspaceImageThumbnailLoading {
    public static let defaultMaxPixelSize = 600
    public static let defaultCacheByteBudget = 32 * 1024 * 1024

    private let defaultMaxPixelSize: Int
    private var cache: WorkspaceImageThumbnailCache
    private var inFlight: [WorkspaceImageThumbnailCache.Key: Task<WorkspaceImageThumbnailOutcome, Never>] = [:]

    public init(
        defaultMaxPixelSize: Int = WorkspaceImageThumbnailProvider.defaultMaxPixelSize,
        cacheByteBudget: Int = WorkspaceImageThumbnailProvider.defaultCacheByteBudget
    ) {
        precondition(defaultMaxPixelSize > 0)
        precondition(cacheByteBudget > 0)
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
        let task = Task { [resolved, modificationDate, fileSize, maxPixelSize, cacheKey] in
            await self.decodeAndCache(
                fileURL: resolved.fileURL,
                workspaceRelativePath: resolved.workspaceRelativePath,
                modificationDate: modificationDate,
                fileSize: fileSize,
                maxPixelSize: maxPixelSize,
                cacheKey: cacheKey
            )
        }
        inFlight[cacheKey] = task
        let outcome = await task.value
        inFlight[cacheKey] = nil
        return outcome
    }

    private func decodeAndCache(
        fileURL: URL,
        workspaceRelativePath: String,
        modificationDate: Date,
        fileSize: Int64,
        maxPixelSize: Int,
        cacheKey: WorkspaceImageThumbnailCache.Key
    ) async -> WorkspaceImageThumbnailOutcome {
        // Another waiter may have finished while we were scheduled.
        if let cached = cache.lookup(cacheKey) {
            return .ready(cached)
        }

        do {
            let decoded = try WorkspaceImageThumbnailDecoder.decodePNGThumbnail(
                from: fileURL,
                maxPixelSize: maxPixelSize
            )
            let thumbnail = WorkspaceImageThumbnail(
                pngData: decoded.pngData,
                pixelWidth: decoded.width,
                pixelHeight: decoded.height,
                resolvedWorkspaceRelativePath: workspaceRelativePath,
                contentModificationDate: modificationDate,
                sourceByteCount: fileSize,
                decodedByteCost: decoded.decodedByteCost
            )
            cache.insert(thumbnail, for: cacheKey)
            return .ready(thumbnail)
        } catch let failure as WorkspaceImageThumbnailFailure {
            return .failed(failure)
        } catch {
            return .failed(.decodeFailed)
        }
    }
}
