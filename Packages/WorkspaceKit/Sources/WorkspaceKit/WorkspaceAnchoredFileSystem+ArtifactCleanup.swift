import Darwin
import Foundation

extension WorkspaceAnchoredFileSystem {
    static func removeArtifact(
        named name: String,
        location: WorkspaceFileSystemLocation,
        expectedIdentity: WorkspaceFileSystemIdentity?,
        context: ArtifactRemovalContext,
        unlinkCall: InjectedCall
    ) -> WorkspaceFileWriteArtifactState {
        removeArtifactResult(
            named: name,
            location: location,
            expectedIdentity: expectedIdentity,
            context: context,
            unlinkCall: unlinkCall,
            syncCall: .syncCleanupDirectory
        ).state
    }

    static func removeArtifactResult(
        named name: String,
        location: WorkspaceFileSystemLocation,
        expectedIdentity: WorkspaceFileSystemIdentity?,
        context: ArtifactRemovalContext,
        unlinkCall: InjectedCall,
        syncCall: InjectedCall
    ) -> ArtifactRemovalResult {
        guard let expectedIdentity else {
            return ArtifactRemovalResult(
                state: .removalIndeterminate(location),
                failureReason: .cleanupFailed
            )
        }

        let request = ArtifactCleanupRequest(
            name: name,
            location: location,
            expectedIdentity: expectedIdentity,
            context: context,
            unlinkCall: unlinkCall,
            syncCall: syncCall
        )
        switch quarantineArtifact(request) {
        case let .quarantined(artifact):
            return removeQuarantinedArtifact(artifact)
        case let .failed(result):
            return result
        }
    }

    static func quarantineArtifact(
        _ request: ArtifactCleanupRequest
    ) -> ArtifactQuarantineOutcome {
        do {
            try request.context.chain.validateNamespace()
            try validateArtifactIdentity(
                parentDescriptor: request.context.parentDescriptor,
                name: request.name,
                expectedIdentity: request.expectedIdentity
            )
        } catch {
            return .failed(ArtifactRemovalResult(
                state: .removalIndeterminate(request.location),
                failureReason: normalizedError(error)
            ))
        }

        let quarantineName = ".plainsong-cleanup-\(UUID().uuidString).tmp"
        guard let quarantineLocation = request.location.sibling(named: quarantineName) else {
            return .failed(ArtifactRemovalResult(
                state: .retained(request.location),
                failureReason: .cleanupFailed
            ))
        }
        do {
            try request.context.chain.validateNamespace()
            try validateArtifactIdentity(
                parentDescriptor: request.context.parentDescriptor,
                name: request.name,
                expectedIdentity: request.expectedIdentity
            )
            try request.context.hooks.check(request.unlinkCall)
        } catch {
            return .failed(ArtifactRemovalResult(
                state: artifactStateAfterFailedQuarantine(
                    parentDescriptor: request.context.parentDescriptor,
                    name: request.name,
                    location: request.location,
                    expectedIdentity: request.expectedIdentity
                ),
                failureReason: normalizedError(error)
            ))
        }
        guard secureRename(
            parentDescriptor: request.context.parentDescriptor,
            from: request.name,
            to: quarantineName,
            flags: UInt32(RENAME_EXCL)
        ) == 0 else {
            return .failed(ArtifactRemovalResult(
                state: artifactStateAfterFailedQuarantine(
                    parentDescriptor: request.context.parentDescriptor,
                    name: request.name,
                    location: request.location,
                    expectedIdentity: request.expectedIdentity
                ),
                failureReason: .cleanupFailed
            ))
        }

        do {
            try request.context.chain.validateNamespace()
            try validateArtifactIdentity(
                parentDescriptor: request.context.parentDescriptor,
                name: quarantineName,
                expectedIdentity: request.expectedIdentity
            )
        } catch {
            let retainedLocation = restoreQuarantinedEntry(
                quarantineName: quarantineName,
                originalName: request.name,
                originalLocation: request.location,
                quarantineLocation: quarantineLocation,
                context: request.context
            )
            return .failed(ArtifactRemovalResult(
                state: .removalIndeterminate(retainedLocation),
                failureReason: normalizedError(error)
            ))
        }

        return .quarantined(QuarantinedArtifact(
            request: request,
            name: quarantineName,
            location: quarantineLocation
        ))
    }

    static func removeQuarantinedArtifact(
        _ artifact: QuarantinedArtifact
    ) -> ArtifactRemovalResult {
        let request = artifact.request
        do {
            try request.context.hooks.check(.unlinkQuarantinedArtifact)
            try request.context.chain.validateNamespace()
            try validateArtifactIdentity(
                parentDescriptor: request.context.parentDescriptor,
                name: artifact.name,
                expectedIdentity: request.expectedIdentity
            )
        } catch {
            let retainedLocation = restoreQuarantinedEntry(
                quarantineName: artifact.name,
                originalName: request.name,
                originalLocation: request.location,
                quarantineLocation: artifact.location,
                context: request.context
            )
            let expectedArtifactSurvived = artifactReferencesIdentity(
                parentDescriptor: request.context.parentDescriptor,
                name: artifact.name,
                expectedIdentity: request.expectedIdentity
            ) || artifactReferencesIdentity(
                parentDescriptor: request.context.parentDescriptor,
                name: request.name,
                expectedIdentity: request.expectedIdentity
            )
            return ArtifactRemovalResult(
                state: expectedArtifactSurvived
                    ? .retained(retainedLocation)
                    : .removalIndeterminate(retainedLocation),
                failureReason: normalizedError(error)
            )
        }

        guard unlink(
            parentDescriptor: request.context.parentDescriptor,
            name: artifact.name
        ) == 0 else {
            return ArtifactRemovalResult(
                state: artifactReferencesIdentity(
                    parentDescriptor: request.context.parentDescriptor,
                    name: artifact.name,
                    expectedIdentity: request.expectedIdentity
                ) ? .retained(artifact.location) : .removalIndeterminate(artifact.location),
                failureReason: .cleanupFailed
            )
        }

        do {
            try request.context.chain.validateNamespace()
            try request.context.hooks.check(request.syncCall)
            try syncDirectory(request.context.parentDescriptor)
            try request.context.chain.validateNamespace()
            guard !artifactReferencesIdentity(
                parentDescriptor: request.context.parentDescriptor,
                name: artifact.name,
                expectedIdentity: request.expectedIdentity
            ), !artifactReferencesIdentity(
                parentDescriptor: request.context.parentDescriptor,
                name: request.name,
                expectedIdentity: request.expectedIdentity
            ) else {
                throw WorkspaceAnchoredFileSystemError.cleanupFailed
            }
            return ArtifactRemovalResult(state: .none, failureReason: nil)
        } catch {
            return ArtifactRemovalResult(
                state: .removalIndeterminate(artifact.location),
                failureReason: normalizedError(error)
            )
        }
    }

    static func validateArtifactIdentity(
        parentDescriptor: Int32,
        name: String,
        expectedIdentity: WorkspaceFileSystemIdentity
    ) throws {
        let entry = try directoryEntryIdentity(
            parentDescriptor: parentDescriptor,
            component: name
        )
        guard entry.isRegularFile, entry.identity == expectedIdentity else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
    }

    static func artifactReferencesIdentity(
        parentDescriptor: Int32,
        name: String,
        expectedIdentity: WorkspaceFileSystemIdentity
    ) -> Bool {
        guard let entry = try? directoryEntryIdentity(
            parentDescriptor: parentDescriptor,
            component: name
        ) else {
            return false
        }
        return entry.isRegularFile && entry.identity == expectedIdentity
    }

    static func artifactStateAfterFailedQuarantine(
        parentDescriptor: Int32,
        name: String,
        location: WorkspaceFileSystemLocation,
        expectedIdentity: WorkspaceFileSystemIdentity
    ) -> WorkspaceFileWriteArtifactState {
        artifactReferencesIdentity(
            parentDescriptor: parentDescriptor,
            name: name,
            expectedIdentity: expectedIdentity
        ) ? .retained(location) : .removalIndeterminate(location)
    }

    static func restoreQuarantinedEntry(
        quarantineName: String,
        originalName: String,
        originalLocation: WorkspaceFileSystemLocation,
        quarantineLocation: WorkspaceFileSystemLocation,
        context: ArtifactRemovalContext
    ) -> WorkspaceFileSystemLocation {
        do {
            try context.hooks.check(.restoreQuarantinedArtifact)
            try context.chain.validateNamespace()
            try validateMissingName(
                parentDescriptor: context.parentDescriptor,
                leaf: originalName
            )
            guard secureRename(
                parentDescriptor: context.parentDescriptor,
                from: quarantineName,
                to: originalName,
                flags: UInt32(RENAME_EXCL)
            ) == 0 else {
                return quarantineLocation
            }
            try context.chain.validateNamespace()
            return originalLocation
        } catch {
            return quarantineLocation
        }
    }
}
