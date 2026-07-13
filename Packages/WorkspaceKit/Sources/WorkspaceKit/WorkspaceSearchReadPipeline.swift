import Foundation
import MarkdownCore

extension WorkspaceSearchPipeline {
    func read(
        candidate: WorkspaceSearchCandidate,
        at planIndex: Int
    ) async throws -> WorkspaceSearchReadOutcome {
        try Task.checkCancellation()
        let fileSizeLimit = max(0, request.limits.maximumFileSizeBytes)
        let location: WorkspaceFileSystemLocation
        do {
            location = try request.rootAuthority.location(relativePath: candidate.relativePath)
        } catch {
            return containmentFailureOutcome(candidate, planIndex: planIndex)
        }
        guard FileKind(url: location.fileURL) != nil else {
            return unsupportedPhysicalFileKindOutcome(candidate, planIndex: planIndex)
        }
        if let overlay = candidate.overlay {
            do {
                let fileAuthority = try await reader.validateFileAuthority(at: location)
                try Task.checkCancellation()
                return overlayOutcome(
                    candidate,
                    overlay: overlay,
                    limit: fileSizeLimit,
                    planIndex: planIndex,
                    fileAuthority: fileAuthority
                )
            } catch let error as CancellationError {
                throw error
            } catch {
                return failedReadOutcome(candidate, error: error, planIndex: planIndex, didReadDisk: false)
            }
        }

        do {
            let readResult = try await reader.readFileWithAuthority(
                at: location,
                maximumByteCount: inclusiveLimit(for: fileSizeLimit)
            )
            try Task.checkCancellation()
            return diskOutcome(
                candidate,
                readResult: readResult,
                limit: fileSizeLimit,
                planIndex: planIndex
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            return failedReadOutcome(candidate, error: error, planIndex: planIndex)
        }
    }

    func physicalPreflightFailureOutcome(
        _ candidate: WorkspaceSearchCandidate,
        reason: WorkspaceSearchSkipReason,
        planIndex: Int
    ) -> WorkspaceSearchReadOutcome {
        WorkspaceSearchReadOutcome(
            planIndex: planIndex,
            payload: .skipped(WorkspaceSearchSkippedFile(
                relativePath: candidate.relativePath,
                reason: reason
            )),
            diskReadByteCount: nil
        )
    }

    func skipReason(
        for error: WorkspaceSearchFileReadError
    ) -> WorkspaceSearchSkipReason {
        switch error {
        case .disappeared:
            .disappeared
        case .unreadable:
            .unreadable
        case .symbolicLink:
            .symlinkEscape
        case .notRegularFile:
            .unreadable
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

    func unsupportedPhysicalFileKindOutcome(
        _ candidate: WorkspaceSearchCandidate,
        planIndex: Int
    ) -> WorkspaceSearchReadOutcome {
        WorkspaceSearchReadOutcome(
            planIndex: planIndex,
            payload: .skipped(WorkspaceSearchSkippedFile(
                relativePath: candidate.relativePath,
                reason: .unsupportedPhysicalFileKind
            )),
            diskReadByteCount: nil
        )
    }

    func overlayOutcome(
        _ candidate: WorkspaceSearchCandidate,
        overlay: WorkspaceSearchOverlay,
        limit: Int,
        planIndex: Int,
        fileAuthority: WorkspaceSearchFileAuthority?
    ) -> WorkspaceSearchReadOutcome {
        let byteCount = overlay.text.lengthOfBytes(using: .utf8)
        let payload: WorkspaceSearchReadPayload = byteCount > limit
            ? .skipped(WorkspaceSearchSkippedFile(
                relativePath: candidate.relativePath,
                reason: .oversized(byteCount: byteCount)
            ))
            : .content(
                text: overlay.text,
                relativePath: candidate.relativePath,
                fileAuthority: fileAuthority
            )
        return WorkspaceSearchReadOutcome(planIndex: planIndex, payload: payload, diskReadByteCount: nil)
    }

    func diskOutcome(
        _ candidate: WorkspaceSearchCandidate,
        readResult: WorkspaceSearchFileReadResult,
        limit: Int,
        planIndex: Int
    ) -> WorkspaceSearchReadOutcome {
        let data = readResult.data
        let payload: WorkspaceSearchReadPayload = if data.count > limit {
            .skipped(WorkspaceSearchSkippedFile(
                relativePath: candidate.relativePath,
                reason: .oversized(byteCount: data.count)
            ))
        } else if let text = String(data: data, encoding: .utf8) {
            .content(
                text: text,
                relativePath: candidate.relativePath,
                fileAuthority: readResult.fileAuthority
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
        planIndex: Int,
        didReadDisk: Bool = true
    ) -> WorkspaceSearchReadOutcome {
        let reason: WorkspaceSearchSkipReason = if let error = error as? WorkspaceSearchFileReadError {
            skipReason(for: error)
        } else {
            isMissingFileError(error) ? .disappeared : .unreadable
        }
        return WorkspaceSearchReadOutcome(
            planIndex: planIndex,
            payload: .skipped(WorkspaceSearchSkippedFile(relativePath: candidate.relativePath, reason: reason)),
            diskReadByteCount: didReadDisk ? 0 : nil
        )
    }
}
