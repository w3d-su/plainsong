import Foundation

/// Cancellable, deterministic orchestration for MarkdownCore workspace text search.
public struct WorkspaceSearchService: Sendable {
    private let reader: any WorkspaceSearchFileReading

    public init(reader: any WorkspaceSearchFileReading = WorkspaceSearchDiskFileReader()) {
        self.reader = reader
    }

    /// Starts a search producer. Cancelling or abandoning the consuming stream cancels all
    /// in-flight reads and prevents a completed summary from being emitted.
    public func events(for request: WorkspaceSearchRequest) -> AsyncStream<WorkspaceSearchEvent> {
        AsyncStream { continuation in
            // This is the single controlled stream producer. Read work stays structured inside
            // the pipeline task group; no detached matching tasks are created.
            let producer = Task(priority: .utility) {
                let access = SecurityScopedAccess.startAccessing(request.rootURL)
                defer {
                    access.stop()
                    continuation.finish()
                }

                do {
                    try await WorkspaceSearchPipeline(
                        request: request,
                        reader: reader,
                        continuation: continuation
                    ).run()
                } catch is CancellationError {
                    // Consumer cancellation is a normal terminal condition with no summary.
                } catch {
                    // Every expected file error is represented as a typed skipped-file event.
                    // Unexpected producer failures terminate the stream without a false summary.
                }
            }

            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }
}
