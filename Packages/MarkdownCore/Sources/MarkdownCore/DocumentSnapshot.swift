import Foundation

/// Immutable document state for downstream packages that should not mutate a session.
public struct DocumentSnapshot: Sendable, Equatable {
    public let text: String
    public let version: Int
    public let fileKind: FileKind
    public let fileURL: URL?
    public let isDirty: Bool
    public let statistics: TextStatistics

    public init(
        text: String,
        version: Int,
        fileKind: FileKind,
        fileURL: URL?,
        isDirty: Bool,
        statistics: TextStatistics
    ) {
        self.text = text
        self.version = version
        self.fileKind = fileKind
        self.fileURL = fileURL
        self.isDirty = isDirty
        self.statistics = statistics
    }
}
