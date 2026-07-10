import Foundation

/// Exact UTF-16 source ranges for one inline Markdown image that the syntax layer has
/// already identified. This is a source-model value only; it never performs file access
/// or changes editor presentation.
public struct MarkdownInlineImageRegion: Sendable, Equatable {
    public let sourceRange: NSRange
    public let altTextRange: NSRange
    public let sourcePathRange: NSRange
    /// Includes the surrounding double quotes, for example `"title"`.
    public let titleRange: NSRange?
    public let chromeRanges: MarkdownInlineImageChromeRanges

    public var openingChromeRange: NSRange {
        chromeRanges.opening
    }

    public var separatorChromeRange: NSRange {
        chromeRanges.separator
    }

    public var closingChromeRange: NSRange {
        chromeRanges.closing
    }

    /// Builds a region only when the parser-provided ranges describe an exact supported
    /// inline image form. Ambiguous or unsupported forms deliberately return `nil` so
    /// callers leave the source raw.
    public init?(
        in source: String,
        sourceRange: NSRange,
        altTextRange: NSRange,
        sourcePathRange: NSRange,
        titleRange: NSRange? = nil
    ) {
        let storage = source as NSString
        guard
            sourceRange.isContained(in: storage.length),
            altTextRange.isContained(in: sourceRange),
            sourcePathRange.isContained(in: sourceRange),
            titleRange.map({ $0.isContained(in: sourceRange) }) ?? true,
            sourceRange.length >= 5
        else {
            return nil
        }

        let opening = NSRange(location: sourceRange.location, length: 2)
        let separator = NSRange(location: NSMaxRange(altTextRange), length: 2)
        let closing = NSRange(location: NSMaxRange(sourceRange) - 1, length: 1)

        guard
            altTextRange.location == NSMaxRange(opening),
            sourcePathRange.location == NSMaxRange(separator),
            NSMaxRange(separator) <= sourceRange.location + sourceRange.length,
            storage.substring(with: opening) == "![",
            storage.substring(with: separator) == "](",
            storage.substring(with: closing) == ")",
            sourcePathRange.length > 0
        else {
            return nil
        }

        let sourcePath = storage.substring(with: sourcePathRange)
        guard !Self.isAngleBracketDestination(sourcePath) else {
            return nil
        }

        let sourcePathEnd = NSMaxRange(sourcePathRange)
        if let titleRange {
            guard
                titleRange.location >= sourcePathEnd,
                NSMaxRange(titleRange) <= closing.location,
                Self.isWhitespaceOnly(storage, range: NSRange(
                    location: sourcePathEnd,
                    length: titleRange.location - sourcePathEnd
                )),
                Self.isWhitespaceOnly(storage, range: NSRange(
                    location: NSMaxRange(titleRange),
                    length: closing.location - NSMaxRange(titleRange)
                )),
                Self.isDoubleQuoted(storage.substring(with: titleRange))
            else {
                return nil
            }
        } else if !Self.isWhitespaceOnly(storage, range: NSRange(
            location: sourcePathEnd,
            length: closing.location - sourcePathEnd
        )) {
            return nil
        }

        self.sourceRange = sourceRange
        self.altTextRange = altTextRange
        self.sourcePathRange = sourcePathRange
        self.titleRange = titleRange
        chromeRanges = MarkdownInlineImageChromeRanges(
            opening: opening,
            separator: separator,
            closing: closing
        )
    }

    /// Translates a fragment-local region into document UTF-16 coordinates.
    public func offset(by offset: Int) -> Self {
        Self(
            sourceRange: sourceRange.offset(by: offset),
            altTextRange: altTextRange.offset(by: offset),
            sourcePathRange: sourcePathRange.offset(by: offset),
            titleRange: titleRange?.offset(by: offset),
            chromeRanges: chromeRanges.offset(by: offset)
        )
    }

    private init(
        sourceRange: NSRange,
        altTextRange: NSRange,
        sourcePathRange: NSRange,
        titleRange: NSRange?,
        chromeRanges: MarkdownInlineImageChromeRanges
    ) {
        self.sourceRange = sourceRange
        self.altTextRange = altTextRange
        self.sourcePathRange = sourcePathRange
        self.titleRange = titleRange
        self.chromeRanges = chromeRanges
    }

    private static func isAngleBracketDestination(_ source: String) -> Bool {
        source.hasPrefix("<") && source.hasSuffix(">")
    }

    private static func isDoubleQuoted(_ source: String) -> Bool {
        source.utf16.count >= 2 && source.hasPrefix("\"") && source.hasSuffix("\"")
    }

    private static func isWhitespaceOnly(_ source: NSString, range: NSRange) -> Bool {
        guard range.length >= 0, range.isContained(in: source.length) else {
            return false
        }
        return source.substring(with: range).allSatisfy(\.isWhitespace)
    }
}

public struct MarkdownInlineImageChromeRanges: Sendable, Equatable {
    public let opening: NSRange
    public let separator: NSRange
    public let closing: NSRange

    public init(opening: NSRange, separator: NSRange, closing: NSRange) {
        self.opening = opening
        self.separator = separator
        self.closing = closing
    }

    fileprivate func offset(by offset: Int) -> Self {
        Self(
            opening: opening.offset(by: offset),
            separator: separator.offset(by: offset),
            closing: closing.offset(by: offset)
        )
    }
}

/// Workspace-derived facts about an image source. WorkspaceKit owns resolving and
/// statting paths; MarkdownCore only evaluates this value and never performs file I/O.
public struct MarkdownImageWorkspaceSource: Sendable, Equatable {
    public let source: String
    public let resolvedWorkspaceRelativePath: String?
    public let fileByteCount: Int64?
    public let isInsideWorkspaceRoot: Bool
    public let hasDirectoryScope: Bool

    public init(
        source: String,
        resolvedWorkspaceRelativePath: String?,
        fileByteCount: Int64?,
        isInsideWorkspaceRoot: Bool,
        hasDirectoryScope: Bool
    ) {
        self.source = source
        self.resolvedWorkspaceRelativePath = resolvedWorkspaceRelativePath
        self.fileByteCount = fileByteCount
        self.isInsideWorkspaceRoot = isInsideWorkspaceRoot
        self.hasDirectoryScope = hasDirectoryScope
    }
}

public enum MarkdownImageThumbnailEligibility: Sendable, Equatable {
    case thumbnailEligible
    case stayRaw(MarkdownImageStayRawReason)
}

public enum MarkdownImageStayRawReason: Sendable, Equatable {
    case emptySource
    case remoteHTTPSource(scheme: String)
    case dataSource
    case fileSource
    case unsupportedSourceScheme(String)
    case noDirectoryScope
    case outsideWorkspace
    case unresolvedWorkspacePath
    case unsupportedPathExtension(String)
    case missingFileSize
    case fileTooLarge(actualBytes: Int64, maximumBytes: Int64)
}

/// Shared native raster policy. PreviewKit and WorkspaceKit consume these constants so
/// thumbnail eligibility cannot drift from the existing preview security policy.
public enum MarkdownImageAssetPolicy {
    public static let maximumFileSizeBytes: Int64 = 10 * 1024 * 1024

    public static let mimeTypesByPathExtension: [String: String] = [
        "gif": "image/gif",
        "jpeg": "image/jpeg",
        "jpg": "image/jpeg",
        "png": "image/png",
        "webp": "image/webp",
    ]

    public static let allowedPathExtensions = Set(mimeTypesByPathExtension.keys)

    public static func mimeType(forPathExtension pathExtension: String) -> String? {
        mimeTypesByPathExtension[pathExtension.lowercased()]
    }

    public static func isAllowedPathExtension(_ pathExtension: String) -> Bool {
        mimeType(forPathExtension: pathExtension) != nil
    }
}

public enum MarkdownImageThumbnailPolicy {
    public static func eligibility(
        for source: MarkdownImageWorkspaceSource
    ) -> MarkdownImageThumbnailEligibility {
        let trimmedSource = source.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            return .stayRaw(.emptySource)
        }

        if let scheme = sourceScheme(in: trimmedSource) {
            switch scheme {
            case "http", "https":
                return .stayRaw(.remoteHTTPSource(scheme: scheme))
            case "data":
                return .stayRaw(.dataSource)
            case "file":
                return .stayRaw(.fileSource)
            default:
                return .stayRaw(.unsupportedSourceScheme(scheme))
            }
        }

        guard source.hasDirectoryScope else {
            return .stayRaw(.noDirectoryScope)
        }
        guard source.isInsideWorkspaceRoot else {
            return .stayRaw(.outsideWorkspace)
        }
        guard let path = source.resolvedWorkspaceRelativePath else {
            return .stayRaw(.unresolvedWorkspacePath)
        }

        let pathExtension = (path as NSString).pathExtension.lowercased()
        guard MarkdownImageAssetPolicy.isAllowedPathExtension(pathExtension) else {
            return .stayRaw(.unsupportedPathExtension(pathExtension))
        }
        guard let fileByteCount = source.fileByteCount else {
            return .stayRaw(.missingFileSize)
        }
        guard fileByteCount <= MarkdownImageAssetPolicy.maximumFileSizeBytes else {
            return .stayRaw(.fileTooLarge(
                actualBytes: fileByteCount,
                maximumBytes: MarkdownImageAssetPolicy.maximumFileSizeBytes
            ))
        }
        return .thumbnailEligible
    }

    private static func sourceScheme(in source: String) -> String? {
        guard let colon = source.firstIndex(of: ":") else {
            return nil
        }
        let candidate = source[..<colon]
        guard
            let first = candidate.first,
            first.isASCII,
            first.isLetter,
            candidate.dropFirst().allSatisfy({ character in
                character
                    .isASCII &&
                    (character.isLetter || character
                        .isNumber || character == "+" || character == "-" || character == ".")
            })
        else {
            return nil
        }
        return candidate.lowercased()
    }
}

private extension NSRange {
    func isContained(in outerRange: NSRange) -> Bool {
        location != NSNotFound && length >= 0 && outerRange.length >= 0 &&
            location >= outerRange.location &&
            NSMaxRange(self) <= NSMaxRange(outerRange)
    }

    func isContained(in length: Int) -> Bool {
        location != NSNotFound && self.length >= 0 && location >= 0 && length >= 0 && NSMaxRange(self) <= length
    }

    func offset(by offset: Int) -> NSRange {
        NSRange(location: location + offset, length: length)
    }
}
