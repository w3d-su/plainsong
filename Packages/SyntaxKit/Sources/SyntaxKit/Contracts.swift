import Foundation
import MarkdownCore

public struct SyntaxRequest: Sendable {
    public let requestID: UUID
    public let version: Int
    public let source: String
    public let fileKind: FileKind
    public let visibleRange: NSRange

    public init(requestID: UUID, version: Int, source: String, fileKind: FileKind, visibleRange: NSRange) {
        self.requestID = requestID
        self.version = version
        self.source = source
        self.fileKind = fileKind
        self.visibleRange = visibleRange
    }
}

public struct SyntaxResult: Sendable {
    public let requestID: UUID
    public let version: Int
    public let coveredRange: NSRange
    public let tokens: [MarkdownSyntaxToken]

    public init(requestID: UUID, version: Int, coveredRange: NSRange, tokens: [MarkdownSyntaxToken]) {
        self.requestID = requestID
        self.version = version
        self.coveredRange = coveredRange
        self.tokens = tokens
    }
}

public enum SyntaxFailure: Error, Equatable, Sendable {
    case unavailable
    case invalidRange
    case parserFailed
}

/// The provider serializes parser state off main and throws SyntaxFailure or
/// CancellationError. Cancellation cannot authorize an already-produced result.
public protocol MarkdownSyntaxTokenizing: Sendable {
    func tokens(for request: SyntaxRequest) async throws -> SyntaxResult
}
