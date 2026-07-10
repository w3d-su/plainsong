import Foundation

extension WorkspaceSearchPipeline {
    func read(
        candidate: WorkspaceSearchCandidate,
        at planIndex: Int
    ) async throws -> WorkspaceSearchReadOutcome {
        try Task.checkCancellation()
        let fileSizeLimit = max(0, request.limits.maximumFileSizeBytes)
        if let overlay = candidate.overlay {
            return overlayOutcome(candidate, overlay: overlay, limit: fileSizeLimit, planIndex: planIndex)
        }

        let url: URL
        do {
            // Planning can race with an on-disk symlink replacement. Resolve containment again
            // immediately before opening the file rather than retaining an earlier URL.
            url = try WorkspaceRootContainment.containedURL(
                rootURL: request.rootURL,
                relativePath: candidate.relativePath
            )
        } catch {
            return containmentFailureOutcome(candidate, planIndex: planIndex)
        }

        do {
            let data = try await reader.readFile(
                at: url,
                maximumByteCount: inclusiveLimit(for: fileSizeLimit)
            )
            try Task.checkCancellation()
            return diskOutcome(candidate, data: data, limit: fileSizeLimit, planIndex: planIndex)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failedReadOutcome(candidate, error: error, planIndex: planIndex)
        }
    }

    func containmentFailureOutcome(
        _ candidate: WorkspaceSearchCandidate,
        planIndex: Int
    ) -> WorkspaceSearchReadOutcome {
        WorkspaceSearchReadOutcome(
            planIndex: planIndex,
            payload: .skipped(WorkspaceSearchSkippedFile(
                relativePath: candidate.relativePath,
                reason: .symlinkEscape
            )),
            diskReadByteCount: nil
        )
    }

    func overlayOutcome(
        _ candidate: WorkspaceSearchCandidate,
        overlay: WorkspaceSearchOverlay,
        limit: Int,
        planIndex: Int
    ) -> WorkspaceSearchReadOutcome {
        let byteCount = overlay.text.lengthOfBytes(using: .utf8)
        let payload: WorkspaceSearchReadPayload = byteCount > limit
            ? .skipped(WorkspaceSearchSkippedFile(
                relativePath: candidate.relativePath,
                reason: .oversized(byteCount: byteCount)
            ))
            : .content(
                text: overlay.text,
                relativePath: candidate.relativePath
            )
        return WorkspaceSearchReadOutcome(planIndex: planIndex, payload: payload, diskReadByteCount: nil)
    }

    func diskOutcome(
        _ candidate: WorkspaceSearchCandidate,
        data: Data,
        limit: Int,
        planIndex: Int
    ) -> WorkspaceSearchReadOutcome {
        let payload: WorkspaceSearchReadPayload = if data.count > limit {
            .skipped(WorkspaceSearchSkippedFile(
                relativePath: candidate.relativePath,
                reason: .oversized(byteCount: data.count)
            ))
        } else if let text = String(data: data, encoding: .utf8) {
            .content(
                text: text,
                relativePath: candidate.relativePath
            )
        } else {
            .skipped(WorkspaceSearchSkippedFile(
                relativePath: candidate.relativePath,
                reason: .invalidUTF8
            ))
        }
        return WorkspaceSearchReadOutcome(
            planIndex: planIndex,
            payload: payload,
            diskReadByteCount: data.count
        )
    }

    func failedReadOutcome(
        _ candidate: WorkspaceSearchCandidate,
        error: Error,
        planIndex: Int
    ) -> WorkspaceSearchReadOutcome {
        let reason: WorkspaceSearchSkipReason = if let error = error as? WorkspaceSearchFileReadError {
            error == .disappeared ? .disappeared : .unreadable
        } else {
            isMissingFileError(error) ? .disappeared : .unreadable
        }
        return WorkspaceSearchReadOutcome(
            planIndex: planIndex,
            payload: .skipped(WorkspaceSearchSkippedFile(relativePath: candidate.relativePath, reason: reason)),
            diskReadByteCount: 0
        )
    }
}
