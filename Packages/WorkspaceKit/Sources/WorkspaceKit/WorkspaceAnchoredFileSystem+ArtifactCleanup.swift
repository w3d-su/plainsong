import Darwin
import Foundation

extension WorkspaceAnchoredFileSystem {
    static func removeArtifact(
        named name: String,
        location: WorkspaceFileSystemLocation,
        expectedIdentity: WorkspaceFileSystemIdentity?,
        borrowedDescriptor: Int32?,
        context: ArtifactRemovalContext,
        unlinkCall: InjectedCall
    ) -> WorkspaceFileWriteArtifactState {
        removeArtifactResult(
            named: name,
            location: location,
            expectedIdentity: expectedIdentity,
            borrowedDescriptor: borrowedDescriptor,
            context: context,
            unlinkCall: unlinkCall,
            syncCall: .syncCleanupDirectory
        ).state
    }

    static func removeArtifactResult(
        named name: String,
        location: WorkspaceFileSystemLocation,
        expectedIdentity: WorkspaceFileSystemIdentity?,
        borrowedDescriptor: Int32?,
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
            borrowedDescriptor: borrowedDescriptor,
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
            // Re-validate after the cleanup hook so an unrelated replacement is never moved.
            try request.context.hooks.check(request.unlinkCall)
            try request.context.chain.validateNamespace()
            try validateArtifactIdentity(
                parentDescriptor: request.context.parentDescriptor,
                name: request.name,
                expectedIdentity: request.expectedIdentity
            )
            // RENAME_EXCL only protects the random destination; macOS cannot condition this
            // rename on the validated source inode, leaving a residual production name race.
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
        var ownedDescriptor: Int32?
        do {
            try request.context.chain.validateNamespace()
            try validateArtifactIdentity(
                parentDescriptor: parentDescriptor,
                name: artifact.name,
                expectedIdentity: request.expectedIdentity
            )
            if let borrowedDescriptor = request.borrowedDescriptor {
                openedDescriptor = borrowedDescriptor
            } else {
                openedDescriptor = try openFile(
                    parentDescriptor: parentDescriptor,
                    leaf: artifact.name,
                    flags: O_EVTONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
                ownedDescriptor = openedDescriptor
            }
            let openedMetadata = try regularFileMetadata(descriptor: openedDescriptor)
            guard openedMetadata.identity == expectedIdentity else {
                throw WorkspaceAnchoredFileSystemError.namespaceChanged
            }
        } catch {
            if let ownedDescriptor { Darwin.close(ownedDescriptor) }
            return quarantineRemovalFailure(
                artifact: artifact,
                error: error
            )
        }
        // A writer-owned descriptor is borrowed through cleanup and remains owned by its caller.
        defer {
            if let ownedDescriptor { Darwin.close(ownedDescriptor) }
        }

        // Post-validation / pre-removal boundary. Tests install racers here.
        do {
            try request.context.hooks.check(.unlinkQuarantinedArtifact)
        } catch {
            return quarantineRemovalFailure(
                artifact: artifact,
                error: error
            )
        }

        // Rebind the name to the open-fd identity. macOS lacks identity-conditional unlink;
        // the final hook exposes that residual validation-to-unlinkat race to tests.
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

        return finalizeArtifactRemoval(artifact)
    }

    private static func finalizeArtifactRemoval(
        _ artifact: QuarantinedArtifact
    ) -> ArtifactRemovalResult {
        let request = artifact.request
        do {
            try request.context.chain.validateNamespace()
            try request.context.hooks.check(request.syncCall)
            try syncDirectory(request.context.parentDescriptor)
            for candidate in [
                (name: artifact.name, location: artifact.location),
                (name: request.name, location: request.location),
            ] {
                switch observeArtifactIdentity(
                    parentDescriptor: request.context.parentDescriptor,
                    name: candidate.name,
                    expectedIdentity: request.expectedIdentity,
                    context: request.context
                ) {
                case .matchesExpected:
                    return ArtifactRemovalResult(
                        state: .retained(candidate.location),
                        failureReason: .cleanupFailed
                    )
                case .missingOrDifferent:
                    continue
                case let .inspectionFailed(error):
                    return ArtifactRemovalResult(
                        state: .removalIndeterminate(artifact.location),
                        failureReason: error
                    )
                }
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

    static func observeArtifactIdentity(
        parentDescriptor: Int32,
        name: String,
        expectedIdentity: WorkspaceFileSystemIdentity,
        context: ArtifactRemovalContext
    ) -> ArtifactIdentityObservation {
        do {
            try context.chain.validateNamespace()
        } catch {
            return .inspectionFailed(normalizedError(error))
        }
        let result = Result {
            try directoryEntryIdentity(
                parentDescriptor: parentDescriptor,
                component: name
            )
        }
        do {
            try context.chain.validateNamespace()
        } catch {
            return .inspectionFailed(normalizedError(error))
        }
        switch result {
        case let .success(entry):
            return entry.isRegularFile && entry.identity == expectedIdentity
                ? .matchesExpected
                : .missingOrDifferent
        case let .failure(error):
            return normalizedError(error) == .missing
                ? .missingOrDifferent
                : .inspectionFailed(normalizedError(error))
        }
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
        for candidate in candidates {
            switch observeArtifactIdentity(
                parentDescriptor: context.parentDescriptor,
                name: candidate.name,
                expectedIdentity: expectedIdentity,
                context: context
            ) {
            case .matchesExpected:
                return .retained(candidate.location)
            case .missingOrDifferent:
                continue
            case .inspectionFailed:
                return .removalIndeterminate(fallbackLocation)
            }
        }
        return .removalIndeterminate(fallbackLocation)
    }
}
