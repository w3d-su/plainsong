import Foundation
import MarkdownCore
@testable import PlainsongIOS
import PreviewKitContracts
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

final class PersistenceAssetContractConsumerTests: XCTestCase {
    @MainActor
    func testIndependentPersistenceConsumerReceivesTypedFailureWithoutInventingDocument() async {
        let consumer = PersistenceConsumer(store: StoreDouble())
        do {
            _ = try await consumer.save(IOSDocumentIdentity(rawValue: UUID()))
            XCTFail("Unavailable store must not acknowledge a save")
        } catch let failure as IOSDocumentFailure {
            XCTAssertEqual(failure, .unavailable)
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }
    }

    func testIndependentResourceConsumerKeepsGrantGenerationAndTypedReadFailure() async {
        let context = PreviewAssetAccessContext(
            allowedRoot: URL(fileURLWithPath: "/synthetic"), rootToken: UUID(),
            grantIdentity: UUID(), accessGeneration: 19
        )
        let request = PreviewAssetReadRequest(
            requestID: UUID(), resolvedURL: URL(fileURLWithPath: "/synthetic/image.png"),
            access: context, maximumByteCount: 10 * 1024 * 1024
        )
        let consumer = ResourceConsumer(reader: ReaderDouble())
        do {
            _ = try await consumer.read(request)
            XCTFail("Unavailable reader must not return fake bytes")
        } catch let failure as PreviewAssetReadFailure {
            XCTAssertEqual(failure, .unavailable)
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }
    }

    @MainActor
    func testAccessLeaseCoordinationAndAssetSurfacesCompileForIndependentConsumer() async throws {
        let grant = IOSWorkspaceGrant(
            workspaceID: IOSWorkspaceIdentity(rawValue: UUID()), rootURL: URL(fileURLWithPath: "/synthetic"),
            accessGeneration: 7, scope: .directory
        )
        let access: any IOSWorkspaceAccessProviding = AccessDouble()
        let lease = try access.acquireLease(for: grant)
        let coordinator: any IOSCoordinatedFileAccess = CoordinationDouble()
        let writer: any IOSWorkspaceAssetWriting = AssetDouble()
        let location = IOSFileLocation(
            workspaceID: grant.workspaceID, accessGeneration: grant.accessGeneration, relativePath: "image.png",
            fileURL: grant.rootURL.appendingPathComponent("image.png"), resourceID: nil
        )
        do {
            _ = try await coordinator.read(location, lease: lease, operationID: UUID(), maximumByteCount: 1024)
            XCTFail("Unavailable coordination must fail")
        } catch let failure as IOSWorkspaceFailure { XCTAssertEqual(failure, .unavailable) }
        do {
            _ = try await writer.stage(IOSImageAssetRequest(
                operationID: UUID(), bytes: Data([0]), contentType: "image/png",
                preferredFilename: "image.png", destination: location
            ), grant: grant)
            XCTFail("Unavailable asset writer must fail")
        } catch let failure as IOSAssetStageFailure {
            guard case .failed(.unavailable) = failure else { return XCTFail("Unexpected stage failure") }
        }
        lease.release()
        lease.release()
        XCTAssertTrue(lease.isReleased)
    }
}

@MainActor
private struct PersistenceConsumer {
    let store: any IOSDocumentStore
    func save(_ identity: IOSDocumentIdentity) async throws -> IOSSaveAcknowledgement {
        try await store.save(identity)
    }
}

private struct ResourceConsumer: Sendable {
    let reader: any PreviewAssetReading
    func read(_ request: PreviewAssetReadRequest) async throws -> PreviewAssetReadResult {
        try await reader
            .read(request)
    }
}

private actor ReaderDouble: PreviewAssetReading {
    func read(_: PreviewAssetReadRequest) async throws -> PreviewAssetReadResult {
        throw PreviewAssetReadFailure
            .unavailable
    }
}

@MainActor
private final class StoreDouble: IOSDocumentStore {
    func open(_: IOSFileLocation, lease _: any IOSWorkspaceAccessLease) async throws -> IOSDocumentHandle {
        throw IOSDocumentFailure.unavailable
    }

    func create(at _: IOSFileLocation, initialText _: String,
                lease _: any IOSWorkspaceAccessLease) async throws -> IOSDocumentHandle
    {
        throw IOSDocumentFailure.unavailable
    }

    func save(_: IOSDocumentIdentity) async throws -> IOSSaveAcknowledgement {
        throw IOSDocumentFailure.unavailable
    }

    func close(_: IOSDocumentIdentity) async throws -> IOSDocumentCloseOutcome {
        throw IOSDocumentFailure.unavailable
    }

    func saveCopy(_: IOSDocumentIdentity, destination _: IOSFileLocation,
                  lease _: any IOSWorkspaceAccessLease) async throws -> IOSSaveAcknowledgement
    {
        throw IOSDocumentFailure.unavailable
    }

    func resolveExternal(_: IOSDocumentIdentity, choice _: IOSExternalResolution) async throws {
        throw IOSDocumentFailure.unavailable
    }

    func acknowledgeExternalReload(operationID _: UUID, outcome _: IOSDocumentReloadOutcome) {}
    func state(for _: IOSDocumentIdentity) -> IOSDocumentState? {
        nil
    }

    func snapshot(for _: IOSDocumentIdentity) -> IOSStoredDocumentSnapshot? {
        nil
    }

    func observe(_: @escaping @MainActor (IOSDocumentEvent) -> Void) -> any IOSObservation {
        ObservationDouble()
    }

    func flushForBackground() async -> [IOSDocumentFlushOutcome] {
        []
    }
}

@MainActor
private final class AccessDouble: IOSWorkspaceAccessProviding {
    func open(selectedURL _: URL,
              scope _: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant
    {
        throw IOSWorkspaceFailure.unavailable
    }

    func restore(bookmark _: Data,
                 scope _: IOSWorkspaceScope) async throws -> IOSWorkspaceGrant
    {
        throw IOSWorkspaceFailure.unavailable
    }

    func acquireLease(for grant: IOSWorkspaceGrant) throws -> any IOSWorkspaceAccessLease {
        LeaseDouble(grant: grant)
    }

    func invalidate(_: IOSWorkspaceIdentity) -> UInt64 {
        1
    }

    func snapshot(for _: IOSWorkspaceIdentity) -> IOSWorkspaceSnapshot? {
        nil
    }

    func refresh(_: IOSWorkspaceGrant) async throws -> IOSWorkspaceSnapshot {
        throw IOSWorkspaceFailure.unavailable
    }

    func observe(_: @escaping @MainActor (IOSWorkspaceEvent) -> Void) -> any IOSObservation {
        ObservationDouble()
    }
}

@MainActor
private final class LeaseDouble: IOSWorkspaceAccessLease {
    let grant: IOSWorkspaceGrant
    private(set) var isReleased = false

    init(grant: IOSWorkspaceGrant) {
        self.grant = grant
    }

    func release() {
        isReleased = true
    }
}

private actor CoordinationDouble: IOSCoordinatedFileAccess {
    func read(
        _: IOSFileLocation,
        lease _: any IOSWorkspaceAccessLease,
        operationID _: UUID,
        maximumByteCount _: Int
    ) async throws -> IOSCoordinatedRead {
        throw IOSWorkspaceFailure.unavailable
    }

    func createNewLeaf(
        at _: IOSFileLocation,
        data _: Data,
        lease _: any IOSWorkspaceAccessLease,
        operationID _: UUID
    ) async throws -> IOSCreatedLeaf {
        throw IOSWorkspaceFailure.unavailable
    }

    func directorySnapshot(for _: IOSWorkspaceGrant, lease _: any IOSWorkspaceAccessLease,
                           requestID _: UUID) async throws -> IOSWorkspaceSnapshot
    {
        throw IOSWorkspaceFailure.unavailable
    }

    func events(for _: IOSWorkspaceGrant,
                lease _: any IOSWorkspaceAccessLease) async -> AsyncStream<IOSWorkspaceEvent>
    {
        AsyncStream { $0.finish() }
    }
}

private actor AssetDouble: IOSWorkspaceAssetWriting {
    func stage(_: IOSImageAssetRequest, grant _: IOSWorkspaceGrant) async throws -> IOSStagedImageAsset {
        throw IOSAssetStageFailure.failed(.unavailable)
    }

    func validate(_: IOSStagedImageAsset) async throws {
        throw IOSWorkspaceFailure.unavailable
    }

    func commit(_ asset: IOSStagedImageAsset) async -> IOSAssetCommitOutcome {
        .retained(receipt(asset))
    }

    func rollback(_ asset: IOSStagedImageAsset) async -> IOSAssetRollbackOutcome {
        .retained(receipt(asset))
    }

    private func receipt(_ asset: IOSStagedImageAsset) -> IOSAssetRecoveryReceipt {
        IOSAssetRecoveryReceipt(
            operationID: asset.operationID, targetLocation: asset.targetLocation,
            ownershipToken: asset.ownershipToken, reason: .indeterminate
        )
    }
}

@MainActor
private final class ObservationDouble: IOSObservation {
    func cancel() {}
}
