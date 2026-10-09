import Foundation
import MarkdownCore

/// Serial syntax provider for Mac and iOS source mode.
///
/// Coordinates are absolute UTF-16 `NSRange` values in the complete source string.
/// `SyntaxResult.coveredRange` is the expanded viewport that was actually tokenized.
/// `requestID` and `version` are copied from the request so the consumer can drop a
/// stale reply; they do not authorize a file, a viewport, or a document generation.
///
/// The provider checks cancellation before parsing and again before returning. A
/// cancelled call throws `CancellationError` and does not return tokens that were
/// already built. `SyntaxFailure.invalidRange` is reserved for a range whose location
/// is negative or `NSNotFound`. Ranges past the end of the source are clamped by the
/// existing viewport expansion. `SyntaxFailure.parserFailed` means the pinned
/// tree-sitter languages could not be installed. `SyntaxFailure.unavailable` is not
/// produced here; a missing provider is the consumer's decision.
///
/// `MarkdownSyntaxParser.tokens(in:fileKind:)` still skips inline markup above
/// `inlineParsingLimit` (250_000 UTF-8 bytes). That historical full-document cutoff
/// is not an iOS visible-range performance result. Visible-range requests parse
/// inline markup inside the expanded viewport.
///
/// Tree-sitter `Parser` values stay inside this actor. Callers receive immutable
/// `Sendable` tokens only. The type is not `@unchecked Sendable` and it does not
/// return colors, fonts, or attributed strings. Fold presentation stays on the Mac
/// adapter; this method returns source tokens only.
public actor MarkdownSyntaxTokenizer: MarkdownSyntaxTokenizing {
    private let parser: MarkdownSyntaxParser
    private let isCancelled: @Sendable () -> Bool

    public init() throws {
        let parser: MarkdownSyntaxParser
        do {
            parser = try MarkdownSyntaxParser()
        } catch {
            throw SyntaxFailure.parserFailed
        }
        self.parser = parser
        isCancelled = { Task.isCancelled }
    }

    /// Test seam. Production cancellation still goes through `Task.isCancelled`.
    init(cancellingBeforeReturn: Bool) throws {
        let parser: MarkdownSyntaxParser
        do {
            parser = try MarkdownSyntaxParser()
        } catch {
            throw SyntaxFailure.parserFailed
        }
        self.parser = parser
        if cancellingBeforeReturn {
            isCancelled = { true }
        } else {
            isCancelled = { Task.isCancelled }
        }
    }

    public func tokens(for request: SyntaxRequest) async throws -> SyntaxResult {
        try throwIfCancelled()
        let sourceLength = (request.source as NSString).length
        guard request.visibleRange.location != NSNotFound, request.visibleRange.location >= 0,
              request.visibleRange.length >= 0
        else {
            throw SyntaxFailure.invalidRange
        }

        let coveredRange = MarkdownSyntaxParser.visibleHighlightRange(
            in: request.source,
            requestedRange: request.visibleRange
        )
        let parsedTokens = parser.tokens(
            in: request.source,
            fileKind: request.fileKind,
            visibleRange: request.visibleRange
        )
        try throwIfCancelled()
        guard coveredRange.location >= 0, NSMaxRange(coveredRange) <= sourceLength else {
            throw SyntaxFailure.invalidRange
        }
        return SyntaxResult(
            requestID: request.requestID,
            version: request.version,
            coveredRange: coveredRange,
            tokens: parsedTokens
        )
    }

    private func throwIfCancelled() throws {
        if isCancelled() {
            throw CancellationError()
        }
    }
}
