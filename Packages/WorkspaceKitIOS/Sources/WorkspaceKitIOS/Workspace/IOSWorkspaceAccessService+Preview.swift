import Foundation
import PreviewKitContracts
import WorkspaceCore

extension IOSWorkspaceAccessService: PreviewAssetReading {
    public nonisolated func read(_ request: PreviewAssetReadRequest) async throws -> PreviewAssetReadResult {
        try Task.checkCancellation()
        let lease: any IOSWorkspaceAccessLease
        do {
            lease = try await leaseMatching(request.access)
        } catch {
            throw PreviewAssetReadFailure.accessChanged
        }
        do {
            let location = try await locationForPreview(request, lease: lease)
            let coordinated = try await read(
                location,
                lease: lease,
                operationID: request.requestID,
                maximumByteCount: request.maximumByteCount
            )
            _ = try await requireCurrent(request.access)
            await MainActor.run { lease.release() }
            return PreviewAssetReadResult(
                requestID: request.requestID,
                coordinatedURL: coordinated.location.fileURL,
                bytes: coordinated.data,
                access: request.access
            )
        } catch {
            await MainActor.run { lease.release() }
            if let failure = error as? PreviewAssetReadFailure {
                throw failure
            }
            if error is CancellationError {
                throw error
            }
            let mapped = (error as? IOSWorkspaceFailure) ?? IOSWorkspaceFailureMapping.map(error)
            throw Self.previewFailure(mapped)
        }
    }

    fileprivate func leaseMatching(_ access: PreviewAssetAccessContext) throws -> any IOSWorkspaceAccessLease {
        guard let record = matchingRecord(access) else { throw IOSWorkspaceFailure.grantChanged }
        return try acquireLease(for: record.grant)
    }

    fileprivate func requireCurrent(_ access: PreviewAssetAccessContext) throws {
        guard matchingRecord(access) != nil else { throw PreviewAssetReadFailure.accessChanged }
    }

    fileprivate func locationForPreview(
        _ request: PreviewAssetReadRequest,
        lease: any IOSWorkspaceAccessLease
    ) throws -> IOSFileLocation {
        guard let record = matchingRecord(request.access) else {
            throw PreviewAssetReadFailure.accessChanged
        }
        let relative = relativePreviewPath(root: record.rootURL, file: request.resolvedURL)
        guard let relative else { throw PreviewAssetReadFailure.outsideRoot }
        let location = IOSFileLocation(
            workspaceID: record.workspaceID,
            accessGeneration: record.generation,
            relativePath: relative,
            fileURL: request.resolvedURL,
            resourceID: nil
        )
        try authorize(location, record: record)
        _ = lease
        return location
    }

    fileprivate func relativePreviewPath(root: URL, file: URL) -> String? {
        let rootBytes = IOSWorkspacePathAuthority.pathBytes(root)
        let fileBytes = IOSWorkspacePathAuthority.pathBytes(file)
        guard fileBytes.count > rootBytes.count + 1 else { return nil }
        guard Array(fileBytes.prefix(rootBytes.count)) == rootBytes else { return nil }
        guard fileBytes[rootBytes.count] == UInt8(ascii: "/") else { return nil }
        let remainder = String(decoding: fileBytes.dropFirst(rootBytes.count + 1), as: UTF8.self)
        guard WorkspaceRelativePath(spelling: remainder) != nil else { return nil }
        return remainder
    }

    fileprivate nonisolated static func previewFailure(_ failure: IOSWorkspaceFailure) -> PreviewAssetReadFailure {
        switch failure {
        case .grantChanged:
            .accessChanged
        case .outsideGrant, .invalidPath:
            .outsideRoot
        case .tooLarge:
            .tooLarge
        case .unsupportedType:
            .unsupportedType
        case .unavailable, .permissionDenied, .requiresDirectoryGrant, .notFound, .alreadyExists,
             .readOnly, .downloading, .offline, .coordinationFailed, .indeterminate:
            .providerFailed
        }
    }
}
