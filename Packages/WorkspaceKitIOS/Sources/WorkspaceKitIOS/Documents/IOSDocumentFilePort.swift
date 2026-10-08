import Foundation

enum IOSDocumentFileWriteDisposition: Equatable, Sendable {
    case stored
    case failed
    case indeterminate
}

struct IOSDocumentFileOpenResult: Sendable {
    var data: Data
    var canWrite: Bool
}

enum IOSDocumentFileEvent: Equatable, Sendable {
    case externalChange
    case deleted
    case becameReadOnly
    case downloading
    case offline
    /// UIDocument relocated a file on its own. The new URL is not a grant.
    case unexpectedRelocation(oldURL: URL, newURL: URL)
}

/// The store's only document file seam. Production uses UIDocument. Tests supply a gate.
/// Callbacks must not wrap another NSFileCoordinator around UIDocument's own read or write.
@MainActor
protocol IOSDocumentFilePort: AnyObject {
    var fileURL: URL { get }

    func open() async throws -> IOSDocumentFileOpenResult
    func create(snapshot: Data) async throws
    func save(
        snapshot: Data,
        operationID: UUID,
        completion: @escaping @MainActor (IOSDocumentFileWriteDisposition) -> Void
    )
    func close() async throws
    func setHandler(_ handler: (@MainActor (IOSDocumentFileEvent) -> Void)?)
}
