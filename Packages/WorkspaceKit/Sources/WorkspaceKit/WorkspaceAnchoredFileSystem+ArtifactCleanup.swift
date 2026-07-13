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
                state: artifactState(
                    named: request.name,
                    location: request.location,
                    expectedIdentity: request.expectedIdentity,
                    context: request.context
                ),
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
            // RENAME_EXCL protects only the random sibling destination. macOS cannot condition
            // this rename on the validated source inode. This is the final instrumented
            // boundary; an injected race fails closed before the syscall, while production
            // retains an honest last-check-to-rename name race.
            try request.context.hooks.check(.renameQuarantinedArtifactAfterValidation)
        } catch {
            return .failed(ArtifactRemovalResult(
                state: artifactState(
                    named: request.name,
                    location: request.location,
                    expectedIdentity: request.expectedIdentity,
                    context: request.context
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
                state: artifactState(
                    named: request.name,
                    location: request.location,
                    expectedIdentity: request.expectedIdentity,
                    context: request.context
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
            return .failed(ArtifactRemovalResult(
                state: artifactState(
                    candidates: [
                        (quarantineName, quarantineLocation),
                        (request.name, request.location),
                    ],
                    fallbackLocation: quarantineLocation,
                    expectedIdentity: request.expectedIdentity,
                    context: request.context
                ),
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
        let openedDescriptor: Int32
        do {
            try request.context.chain.validateNamespace()
            try validateArtifactIdentity(
                parentDescriptor: parentDescriptor,
                name: artifact.name,
                expectedIdentity: request.expectedIdentity
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
                error: error
            )
        }
        defer { Darwin.close(openedDescriptor) }

        // Post-validation / pre-removal boundary. Tests install racers here.
        do {
            try request.context.hooks.check(.unlinkQuarantinedArtifact)
        } catch {
            return quarantineRemovalFailure(
                artifact: artifact,
                error: error
            )
        }

        // Rebind the name to the open-fd identity. macOS has no regular-file fd unlink or
        // identity-conditional unlink. The final hook exposes the last validation-to-unlinkat
        // boundary; an injected race fails closed. Production retains that residual name race.
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
            try request.context.hooks.check(.unlinkQuarantinedArtifactAfterValidation)
        } catch {
            return quarantineRemovalFailure(
                artifact: artifact,
                error: error
            )
        }

        guard unlink(parentDescriptor: parentDescriptor, name: artifact.name) == 0 else {
            return ArtifactRemovalResult(
                state: artifactState(
                    named: artifact.name,
                    location: artifact.location,
                    expectedIdentity: expectedIdentity,
                    context: request.context
                ),
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

    /// Quarantined material is never republished through a mutable source name. A failure leaves
    /// the current names untouched and reports retained only when the exact expected identity is
    /// proven at the returned location.
    private static func quarantineRemovalFailure(
        artifact: QuarantinedArtifact,
        error: Error
    ) -> ArtifactRemovalResult {
        let request = artifact.request
        return ArtifactRemovalResult(
            state: artifactState(
                candidates: [
                    (artifact.name, artifact.location),
                    (request.name, request.location),
                ],
                fallbackLocation: artifact.location,
                expectedIdentity: request.expectedIdentity,
                context: request.context
            ),
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

    static func artifactState(
        named name: String,
        location: WorkspaceFileSystemLocation,
        expectedIdentity: WorkspaceFileSystemIdentity,
        context: ArtifactRemovalContext
    ) -> WorkspaceFileWriteArtifactState {
        artifactState(
            candidates: [(name, location)],
            fallbackLocation: location,
            expectedIdentity: expectedIdentity,
            context: context
        )
    }

    static func artifactState(
        candidates: [(name: String, location: WorkspaceFileSystemLocation)],
        fallbackLocation: WorkspaceFileSystemLocation,
        expectedIdentity: WorkspaceFileSystemIdentity,
        context: ArtifactRemovalContext
    ) -> WorkspaceFileWriteArtifactState {
        do {
            try context.chain.validateNamespace()
        } catch {
            return .removalIndeterminate(fallbackLocation)
        }
        for candidate in candidates where artifactReferencesIdentity(
            parentDescriptor: context.parentDescriptor,
            name: candidate.name,
            expectedIdentity: expectedIdentity
        ) {
            return .retained(candidate.location)
        }
        return .removalIndeterminate(fallbackLocation)
    }
}
