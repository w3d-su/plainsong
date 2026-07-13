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
            // Pre-quarantine boundary for temporary/rollback artifact hooks. Re-validate after
            // the hook so an unrelated replacement is never moved into quarantine.
            try request.context.hooks.check(request.unlinkCall)
            try request.context.chain.validateNamespace()
            try validateArtifactIdentity(
                parentDescriptor: request.context.parentDescriptor,
                name: request.name,
                expectedIdentity: request.expectedIdentity
            )
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
                expectedIdentity: request.expectedIdentity,
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
        let parentDescriptor = request.context.parentDescriptor
        let expectedIdentity = request.expectedIdentity

        // Bind an open descriptor to the writer-owned inode before any destructive name op.
        // macOS has no funlinkat/fd-unlink for regular files, so name removal is only attempted
        // while this open identity still matches the directory entry after the final hook.
        let openedDescriptor: Int32
        do {
            try request.context.chain.validateNamespace()
            try validateArtifactIdentity(
                parentDescriptor: parentDescriptor,
                name: artifact.name,
                expectedIdentity: expectedIdentity
            )
            openedDescriptor = try openFile(
                parentDescriptor: parentDescriptor,
                leaf: artifact.name,
                flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            let openedMetadata = try regularFileMetadata(descriptor: openedDescriptor)
            guard openedMetadata.identity == expectedIdentity else {
                Darwin.close(openedDescriptor)
                throw WorkspaceAnchoredFileSystemError.namespaceChanged
            }
        } catch {
            return quarantineRemovalFailure(
                artifact: artifact,
                error: error,
                allowRestore: true
            )
        }
        defer { Darwin.close(openedDescriptor) }

        // Post-validation / pre-removal boundary. Tests install racers here.
        do {
            try request.context.hooks.check(.unlinkQuarantinedArtifact)
        } catch {
            return quarantineRemovalFailure(
                artifact: artifact,
                error: error,
                allowRestore: true
            )
        }

        // Rebind the name to the open-fd identity. A replacement must survive untouched;
        // refuse destructive removal rather than unlinking an unrelated entry. A residual
        // TOCTOU remains between this check and unlinkat on platforms without fd-unlink;
        // the contract claims refusal-on-mismatch plus private quarantine isolation, not
        // absolute atomicity of the final name removal.
        do {
            try request.context.chain.validateNamespace()
            let entry = try directoryEntryIdentity(
                parentDescriptor: parentDescriptor,
                component: artifact.name
            )
            let openedIdentity = try regularFileMetadata(descriptor: openedDescriptor).identity
            guard entry.isRegularFile,
                  entry.identity == expectedIdentity,
                  entry.identity == openedIdentity
            else {
                throw WorkspaceAnchoredFileSystemError.namespaceChanged
            }
        } catch {
            return quarantineRemovalFailure(
                artifact: artifact,
                error: error,
                allowRestore: false
            )
        }

        guard unlink(parentDescriptor: parentDescriptor, name: artifact.name) == 0 else {
            return ArtifactRemovalResult(
                state: artifactReferencesIdentity(
                    parentDescriptor: parentDescriptor,
                    name: artifact.name,
                    expectedIdentity: expectedIdentity
                ) ? .retained(artifact.location) : .removalIndeterminate(artifact.location),
                failureReason: .cleanupFailed
            )
        }

        do {
            try request.context.chain.validateNamespace()
            try request.context.hooks.check(request.syncCall)
            try syncDirectory(parentDescriptor)
            try request.context.chain.validateNamespace()
            guard !artifactReferencesIdentity(
                parentDescriptor: parentDescriptor,
                name: artifact.name,
                expectedIdentity: expectedIdentity
            ), !artifactReferencesIdentity(
                parentDescriptor: parentDescriptor,
                name: request.name,
                expectedIdentity: expectedIdentity
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

    /// Handles a failed quarantine removal. `allowRestore` is true only when the writer still
    /// believes the quarantine name may hold writer-owned material (validation/open failure or
    /// injected pre-removal fault). After a post-hook rebind mismatch, restore is forbidden so
    /// an unrelated replacement is never published back to the original name.
    private static func quarantineRemovalFailure(
        artifact: QuarantinedArtifact,
        error: Error,
        allowRestore: Bool
    ) -> ArtifactRemovalResult {
        let request = artifact.request
        let retainedLocation: WorkspaceFileSystemLocation = if allowRestore {
            restoreQuarantinedEntry(
                quarantineName: artifact.name,
                originalName: request.name,
                originalLocation: request.location,
                quarantineLocation: artifact.location,
                expectedIdentity: request.expectedIdentity,
                context: request.context
            )
        } else {
            artifactReferencesIdentity(
                parentDescriptor: request.context.parentDescriptor,
                name: artifact.name,
                expectedIdentity: request.expectedIdentity
            ) ? artifact.location : request.location
        }
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
        expectedIdentity: WorkspaceFileSystemIdentity,
        context: ArtifactRemovalContext
    ) -> WorkspaceFileSystemLocation {
        do {
            try context.hooks.check(.restoreQuarantinedArtifact)
            try context.chain.validateNamespace()
            // Only restore writer-owned material. An unrelated replacement at the quarantine
            // name must stay put, including when the original destination name is absent.
            try validateArtifactIdentity(
                parentDescriptor: context.parentDescriptor,
                name: quarantineName,
                expectedIdentity: expectedIdentity
            )
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
                return artifactReferencesIdentity(
                    parentDescriptor: context.parentDescriptor,
                    name: quarantineName,
                    expectedIdentity: expectedIdentity
                ) ? quarantineLocation : originalLocation
            }
            try context.chain.validateNamespace()
            guard artifactReferencesIdentity(
                parentDescriptor: context.parentDescriptor,
                name: originalName,
                expectedIdentity: expectedIdentity
            ) else {
                return quarantineLocation
            }
            return originalLocation
        } catch {
            return artifactReferencesIdentity(
                parentDescriptor: context.parentDescriptor,
                name: quarantineName,
                expectedIdentity: expectedIdentity
            ) ? quarantineLocation : originalLocation
        }
    }
}
