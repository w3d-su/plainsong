import Foundation

/// Cancellable, deterministic orchestration for MarkdownCore workspace text search.
public struct WorkspaceSearchService: Sendable {
    private let reader: any WorkspaceSearchFileReading
    private let failureInjector: WorkspaceSearchPipelineFailureInjector

    public init(reader: any WorkspaceSearchFileReading = WorkspaceSearchDiskFileReader()) {
        self.reader = reader
        failureInjector = .disabled
    }

    init(
        reader: any WorkspaceSearchFileReading,
        failurePoint: WorkspaceSearchPipelineFailurePoint
    ) {
        self.reader = reader
        failureInjector = WorkspaceSearchPipelineFailureInjector(failurePoint: failurePoint)
    }

    /// Starts a search producer. Early termination requires explicitly cancelling the Task
    /// consuming this stream; breaking or abandoning iteration alone is not a cancellation
    /// contract. Cancelling that Task stops all in-flight reads and suppresses terminal events.
    public func events(for request: WorkspaceSearchRequest) -> AsyncStream<WorkspaceSearchEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            // This is the single controlled stream producer. Read work stays structured inside
            // the pipeline task group; no detached matching tasks are created.
            let producer = Task(priority: .utility) {
                let access = SecurityScopedAccess.startAccessing(
                    request.rootAuthority.securityScopedURL
                )
                defer {
                    access.stop()
                    continuation.finish()
                }

                do {
                    try await WorkspaceSearchPipeline(
                        request: request,
                        reader: reader,
                        continuation: continuation,
                        failureInjector: failureInjector
                    ).run()
                } catch {
                    // Only cancellation of this producer task is a normal silent terminal
                    // condition. A reader can independently throw CancellationError, which is
                    // an unexpected producer failure when this task remains active.
                    guard !Task.isCancelled else { return }
                    // Every expected file error is represented as a typed skipped-file event.
                    // Unexpected producer failures are observable and never masquerade as success.
                    continuation.yield(.failed(
                        WorkspaceSearchContext(
                            rootIdentity: request.rootIdentity,
                            workspaceGeneration: request.workspaceGeneration,
                            queryGeneration: request.queryGeneration
                        ),
                        .unexpectedProducerFailure
                    ))
                }
            }

            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }
}
