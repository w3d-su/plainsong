import Darwin
import Foundation

public enum WorkspaceAnchoredItemCreator {
    static func makeStagingLocation(
        rootAuthority: WorkspaceFileSystemRootAuthority,
        excluding destination: WorkspaceFileSystemLocation
    ) throws -> WorkspaceFileSystemLocation {
        let rootExpectation = rootAuthority.directoryMutationExpectation
        for _ in 0 ..< 16 {
            let name = ".plainsong-create-\(UUID().uuidString.lowercased())"
            let location = try rootAuthority.location(relativePath: name)
            guard location != destination else { continue }
            guard try WorkspaceNoFollowItemInspector.inspectParent(of: location)
                == rootExpectation
            else {
                throw WorkspaceItemMutationFailure.destinationChanged
            }
            do {
                _ = try WorkspaceNoFollowItemInspector.inspectExact(at: location)
            } catch WorkspaceAnchoredFileSystemError.missing {
                return location
            }
        }
        throw WorkspaceItemMutationFailure.destinationExists
    }

    static func createFile(
        using plan: WorkspaceItemCreationPlan,
        recordingCreatedArtifact:
        @escaping (WorkspacePreparedItemCreationArtifact) throws -> Void = { _ in }
    ) -> WorkspaceItemCreationOutcome {
        createFile(
            using: plan,
            recordingCreatedArtifact: recordingCreatedArtifact,
            hooks: .production
        )
    }

    static func createDirectory(
        using plan: WorkspaceItemCreationPlan,
        recordingCreatedArtifact:
        @escaping (WorkspacePreparedItemCreationArtifact) throws -> Void = { _ in }
    ) -> WorkspaceItemCreationOutcome {
        createDirectory(
            using: plan,
            recordingCreatedArtifact: recordingCreatedArtifact,
            hooks: .production
        )
    }

    static func createFile(
        at destination: WorkspaceFileSystemLocation,
        expectingParent parentExpectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceItemCreationOutcome {
        createFile(
            at: destination,
            expectingParent: parentExpectation,
            hooks: .production
        )
    }

    static func createDirectory(
        at destination: WorkspaceFileSystemLocation,
        expectingParent parentExpectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceItemCreationOutcome {
        createDirectory(
            at: destination,
            expectingParent: parentExpectation,
            hooks: .production
        )
    }

    static func createFile(
        at destination: WorkspaceFileSystemLocation,
        expectingParent parentExpectation: WorkspaceItemMutationExpectation,
        hooks: WorkspaceAnchoredFileSystem.Hooks
    ) -> WorkspaceItemCreationOutcome {
        do {
            let plan = try WorkspaceItemCreationPlan(
                kind: .file,
                destination: destination,
                parentExpectation: parentExpectation,
                stagingLocation: makeStagingLocation(
                    rootAuthority: destination.rootAuthority,
                    excluding: destination
                )
            )
            return createFile(
                using: plan,
                recordingCreatedArtifact: { _ in },
                hooks: hooks
            )
        } catch {
            return .notCreated(creationFailure(for: error))
        }
    }

    static func createDirectory(
        at destination: WorkspaceFileSystemLocation,
        expectingParent parentExpectation: WorkspaceItemMutationExpectation,
        hooks: WorkspaceItemCreationHooks
    ) -> WorkspaceItemCreationOutcome {
        do {
            let plan = try WorkspaceItemCreationPlan(
                kind: .folder,
                destination: destination,
                parentExpectation: parentExpectation,
                stagingLocation: makeStagingLocation(
                    rootAuthority: destination.rootAuthority,
                    excluding: destination
                )
            )
            return createDirectory(
                using: plan,
                recordingCreatedArtifact: { _ in },
                hooks: hooks
            )
        } catch {
            return .notCreated(creationFailure(for: error))
        }
    }

    static func createFile(
        using plan: WorkspaceItemCreationPlan,
        recordingCreatedArtifact:
        @escaping (WorkspacePreparedItemCreationArtifact) throws -> Void,
        hooks: WorkspaceAnchoredFileSystem.Hooks
    ) -> WorkspaceItemCreationOutcome {
        guard let stagingLocation = validStagingLocation(for: plan, kind: .file) else {
            return .notCreated(.invalidName)
        }
        switch prepareFileArtifact(
            at: stagingLocation,
            destination: plan.destination,
            hooks: hooks
        ) {
        case let .failed(outcome):
            return outcome
        case let .prepared(prepared):
            return publish(
                prepared,
                using: plan,
                recordingCreatedArtifact: recordingCreatedArtifact,
                mutationHooks: filePublicationHooks(hooks),
                preparingCommit: { _ in () },
                terminalValidation: {
                    hooks.emit(.postflight)
                    try validatePublishedFile(prepared.artifact, plan: plan)
                }
            )
        }
    }

    static func createDirectory(
        using plan: WorkspaceItemCreationPlan,
        recordingCreatedArtifact:
        @escaping (WorkspacePreparedItemCreationArtifact) throws -> Void,
        hooks: WorkspaceItemCreationHooks
    ) -> WorkspaceItemCreationOutcome {
        guard let stagingLocation = validStagingLocation(for: plan, kind: .folder) else {
            return .notCreated(.invalidName)
        }
        switch prepareDirectoryArtifact(
            at: stagingLocation,
            destination: plan.destination,
            hooks: hooks
        ) {
        case let .failed(outcome):
            return outcome
        case let .prepared(prepared):
            return publish(
                prepared,
                using: plan,
                recordingCreatedArtifact: recordingCreatedArtifact,
                mutationHooks: directoryPublicationHooks(hooks),
                preparingCommit: { _ in hooks.emit(.didCreate) },
                terminalValidation: {
                    hooks.emit(.postflight)
                    try validatePublishedDirectory(prepared, plan: plan)
                }
            )
        }
    }
}

private extension WorkspaceAnchoredItemCreator {
    struct PreparedCreationArtifact {
        let artifact: WorkspacePreparedItemCreationArtifact
        let directoryPolicy: WorkspaceDirectoryClonePolicy?
    }

    enum StagingPreparation {
        case prepared(PreparedCreationArtifact)
        case failed(WorkspaceItemCreationOutcome)
    }

    static func validStagingLocation(
        for plan: WorkspaceItemCreationPlan,
        kind: WorkspaceItemCreationPlanKind
    ) -> WorkspaceFileSystemLocation? {
        guard plan.kind == kind,
              let stagingLocation = plan.stagingLocation,
              stagingLocation.rootAuthority == plan.destination.rootAuthority,
              stagingLocation != plan.destination,
              !stagingLocation.relativePath.isEmpty,
              !stagingLocation.relativePath.utf8.contains(0x2F),
              stagingLocation.relativePath.hasPrefix(".plainsong-create-")
        else {
            return nil
        }
        return stagingLocation
    }

    // swiftlint:disable:next function_body_length
    static func prepareFileArtifact(
        at stagingLocation: WorkspaceFileSystemLocation,
        destination: WorkspaceFileSystemLocation,
        hooks: WorkspaceAnchoredFileSystem.Hooks
    ) -> StagingPreparation {
        do {
            return try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(
                to: stagingLocation
            ) {
                try WorkspaceAnchoredFileSystem.withAnchoredParent(
                    at: stagingLocation,
                    hooks: hooks
                ) { chain, parentDescriptor, leaf in
                    let rootExpectation = stagingLocation.rootAuthority
                        .directoryMutationExpectation
                    try WorkspaceAnchoredFileSystem.validateDirectoryMutationExpectation(
                        parentDescriptor: parentDescriptor,
                        expectation: rootExpectation
                    )
                    do {
                        try WorkspaceAnchoredFileSystem.validateMissingName(
                            parentDescriptor: parentDescriptor,
                            leaf: leaf
                        )
                    } catch WorkspaceAnchoredFileSystemError.changedIdentity {
                        return .failed(.notCreated(.destinationExists))
                    }
                    try chain.validateNamespace()
                    try WorkspaceAnchoredFileSystem.checkCancellation()

                    let descriptor = leaf.withCString {
                        Darwin.openat(
                            parentDescriptor,
                            $0,
                            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC
                                | O_NOFOLLOW_ANY,
                            mode_t(S_IRUSR | S_IWUSR)
                        )
                    }
                    guard descriptor >= 0 else {
                        return .failed(.notCreated(containedCreationFailure(errno)))
                    }
                    defer { Darwin.close(descriptor) }

                    let metadata: WorkspaceCoherentFileMetadata
                    do {
                        metadata = try WorkspaceAnchoredFileSystem.regularFileMetadata(
                            descriptor: descriptor
                        )
                    } catch {
                        return .failed(indeterminateStagingCreation(
                            destination: destination,
                            stagingLocation: stagingLocation,
                            reason: creationFailure(for: error),
                            expectedArtifact: nil
                        ))
                    }
                    let artifact = WorkspacePreparedItemCreationArtifact(
                        location: stagingLocation,
                        expectation: WorkspaceItemMutationExpectation(
                            identity: metadata.identity,
                            kind: .regularFile
                        )
                    )

                    do {
                        try chain.validateNamespace()
                        try WorkspaceAnchoredFileSystem
                            .validateNameStillReferencesDescriptor(
                                parentDescriptor: parentDescriptor,
                                leaf: leaf,
                                metadata: metadata
                            )
                        guard Darwin.fsync(descriptor) == 0 else {
                            throw WorkspaceAnchoredFileSystemError.durabilityFailed
                        }
                        try hooks.check(.syncCommittedDirectory)
                        try WorkspaceAnchoredFileSystem.syncDirectory(parentDescriptor)
                        try WorkspaceAnchoredFileSystem
                            .validateDirectoryMutationExpectation(
                                parentDescriptor: parentDescriptor,
                                expectation: rootExpectation
                            )
                        try WorkspaceAnchoredFileSystem
                            .validateNameStillReferencesDescriptor(
                                parentDescriptor: parentDescriptor,
                                leaf: leaf,
                                metadata: metadata
                            )
                        try chain.validateNamespace()
                        guard try WorkspaceNoFollowItemInspector.inspectExact(
                            at: stagingLocation
                        ) == artifact.expectation else {
                            throw WorkspaceAnchoredFileSystemError.namespaceChanged
                        }
                    } catch {
                        return .failed(indeterminateStagingCreation(
                            destination: destination,
                            stagingLocation: stagingLocation,
                            reason: creationFailure(for: error),
                            expectedArtifact: artifact
                        ))
                    }
                    return .prepared(.init(
                        artifact: artifact,
                        directoryPolicy: nil
                    ))
                }
            }
        } catch {
            return .failed(.notCreated(creationFailure(for: error)))
        }
    }

    // swiftlint:disable:next function_body_length
    static func prepareDirectoryArtifact(
        at stagingLocation: WorkspaceFileSystemLocation,
        destination: WorkspaceFileSystemLocation,
        hooks: WorkspaceItemCreationHooks
    ) -> StagingPreparation {
        do {
            return try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(
                to: stagingLocation
            ) {
                try WorkspaceAnchoredFileSystem.withAnchoredParent(
                    at: stagingLocation,
                    hooks: .production
                ) { chain, parentDescriptor, leaf in
                    let rootExpectation = stagingLocation.rootAuthority
                        .directoryMutationExpectation
                    try WorkspaceAnchoredFileSystem.validateDirectoryMutationExpectation(
                        parentDescriptor: parentDescriptor,
                        expectation: rootExpectation
                    )
                    do {
                        try WorkspaceAnchoredFileSystem.validateMissingName(
                            parentDescriptor: parentDescriptor,
                            leaf: leaf
                        )
                    } catch WorkspaceAnchoredFileSystemError.changedIdentity {
                        return .failed(.notCreated(.destinationExists))
                    }
                    try hooks.check(.createDirectory)
                    try chain.validateNamespace()
                    try WorkspaceAnchoredFileSystem.checkCancellation()

                    let cloneResult: WorkspaceDirectoryCloneResult
                    do {
                        cloneResult = try cloneTrustedEmptyDirectory(
                            to: stagingLocation,
                            hooks: hooks
                        )
                    } catch {
                        return .failed(.notCreated(creationFailure(for: error)))
                    }

                    let createdDescriptor: Int32
                    do {
                        createdDescriptor = try openContainedDirectory(
                            at: stagingLocation
                        )
                    } catch {
                        return .failed(indeterminateStagingCreation(
                            destination: destination,
                            stagingLocation: stagingLocation,
                            reason: creationFailure(for: error),
                            expectedArtifact: nil
                        ))
                    }
                    defer { Darwin.close(createdDescriptor) }

                    let artifact: WorkspacePreparedItemCreationArtifact
                    let policy: WorkspaceDirectoryClonePolicy
                    do {
                        let entry = try directoryEntryIdentity(
                            descriptor: createdDescriptor
                        )
                        artifact = WorkspacePreparedItemCreationArtifact(
                            location: stagingLocation,
                            expectation: entry.mutationExpectation
                        )
                        policy = try WorkspaceDirectoryCloneSourceSupport
                            .captureCreatedDirectoryPolicy(
                                descriptor: createdDescriptor
                            )
                    } catch {
                        return .failed(indeterminateStagingCreation(
                            destination: destination,
                            stagingLocation: stagingLocation,
                            reason: creationFailure(for: error),
                            expectedArtifact: nil
                        ))
                    }

                    guard cloneResult.sourceRemainedExact else {
                        return .failed(indeterminateStagingCreation(
                            destination: destination,
                            stagingLocation: stagingLocation,
                            reason: .namespaceChanged,
                            expectedArtifact: artifact
                        ))
                    }
                    do {
                        try validateStagedDirectory(
                            descriptor: createdDescriptor,
                            artifact: artifact,
                            policy: policy,
                            chain: chain,
                            parentDescriptor: parentDescriptor,
                            leaf: leaf,
                            rootExpectation: rootExpectation
                        )
                        try hooks.check(.syncCreatedDirectory)
                        guard Darwin.fsync(createdDescriptor) == 0 else {
                            throw WorkspaceItemMutationFailure.durabilityFailed
                        }
                        hooks.emit(.willSyncParent)
                        try hooks.check(.syncParent)
                        try WorkspaceAnchoredFileSystem.syncDirectory(parentDescriptor)
                        try validateStagedDirectory(
                            descriptor: createdDescriptor,
                            artifact: artifact,
                            policy: policy,
                            chain: chain,
                            parentDescriptor: parentDescriptor,
                            leaf: leaf,
                            rootExpectation: rootExpectation
                        )
                    } catch {
                        return .failed(indeterminateStagingCreation(
                            destination: destination,
                            stagingLocation: stagingLocation,
                            reason: creationFailure(for: error),
                            expectedArtifact: artifact
                        ))
                    }
                    return .prepared(.init(
                        artifact: artifact,
                        directoryPolicy: policy
                    ))
                }
            }
        } catch {
            return .failed(.notCreated(creationFailure(for: error)))
        }
    }

    // swiftlint:disable:next function_body_length function_parameter_count
    static func publish(
        _ prepared: PreparedCreationArtifact,
        using plan: WorkspaceItemCreationPlan,
        recordingCreatedArtifact:
        (WorkspacePreparedItemCreationArtifact) throws -> Void,
        mutationHooks: WorkspaceItemMutationHooks,
        preparingCommit: (WorkspaceItemRelocation) throws -> some Any,
        terminalValidation: () throws -> Void
    ) -> WorkspaceItemCreationOutcome {
        do {
            try recordingCreatedArtifact(prepared.artifact)
        } catch {
            return indeterminatePreparedCreation(
                prepared.artifact,
                plan: plan,
                reason: .commitPreparationFailed,
                actualPublishedExpectation: nil
            )
        }

        let outcome = WorkspaceAnchoredItemMutator.relocate(
            prepared.artifact.location,
            to: plan.destination,
            expecting: prepared.artifact.expectation,
            sourceParentExpectation: prepared.artifact.location.rootAuthority
                .directoryMutationExpectation,
            destinationParentExpectation: plan.parentExpectation,
            preparingCommit: preparingCommit,
            hooks: mutationHooks
        )
        switch outcome {
        case let .notMoved(reason):
            return indeterminatePreparedCreation(
                prepared.artifact,
                plan: plan,
                reason: reason,
                actualPublishedExpectation: nil
            )
        case let .movedButIndeterminate(indeterminate):
            return indeterminatePreparedCreation(
                prepared.artifact,
                plan: plan,
                reason: indeterminate.reason,
                actualPublishedExpectation: indeterminate.actualMovedExpectation
                    ?? provenExpectedPublication(
                        prepared.artifact,
                        destination: plan.destination
                    )
            )
        case .movedAndDurable:
            do {
                try terminalValidation()
                return .createdAndDurable(.init(
                    location: plan.destination,
                    expectation: prepared.artifact.expectation
                ))
            } catch {
                return indeterminatePreparedCreation(
                    prepared.artifact,
                    plan: plan,
                    reason: creationFailure(for: error),
                    actualPublishedExpectation: prepared.artifact.expectation
                )
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func validateStagedDirectory(
        descriptor: Int32,
        artifact: WorkspacePreparedItemCreationArtifact,
        policy: WorkspaceDirectoryClonePolicy,
        chain: WorkspaceAnchoredFileSystem.DirectoryDescriptorChain,
        parentDescriptor: Int32,
        leaf: String,
        rootExpectation: WorkspaceItemMutationExpectation
    ) throws {
        try chain.validateNamespace()
        try WorkspaceAnchoredFileSystem.validateDirectoryMutationExpectation(
            parentDescriptor: parentDescriptor,
            expectation: rootExpectation
        )
        guard try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(descriptor)
            == artifact.expectation.identity
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        try WorkspaceDirectoryCloneSourceSupport.validateCreatedDirectory(
            descriptor: descriptor,
            expecting: policy
        )
        guard let entry = try WorkspaceAnchoredFileSystem.exactDirectoryEntry(
            parentDescriptor: parentDescriptor,
            leaf: leaf
        ), entry.mutationExpectation == artifact.expectation else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        try chain.validateNamespace()
    }

    static func validatePublishedFile(
        _ artifact: WorkspacePreparedItemCreationArtifact,
        plan: WorkspaceItemCreationPlan
    ) throws {
        guard try WorkspaceNoFollowItemInspector.inspectParent(of: plan.destination)
            == plan.parentExpectation,
            try WorkspaceNoFollowItemInspector.inspectExact(at: plan.destination)
            == artifact.expectation,
            try WorkspaceNoFollowItemInspector.inspectParent(of: plan.destination)
            == plan.parentExpectation
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
    }

    static func validatePublishedDirectory(
        _ prepared: PreparedCreationArtifact,
        plan: WorkspaceItemCreationPlan
    ) throws {
        guard let policy = prepared.directoryPolicy else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        try validatePublishedFile(prepared.artifact, plan: plan)
        let descriptor = try openContainedDirectory(at: plan.destination)
        defer { Darwin.close(descriptor) }
        guard try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(descriptor)
            == prepared.artifact.expectation.identity
        else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        let publishedPolicy = try WorkspaceDirectoryCloneSourceSupport
            .captureCreatedDirectoryPolicy(descriptor: descriptor)
        // rename(2) legitimately advances a directory's ctime. The publication boundary
        // must still preserve the trusted clone's complete xattr policy; the fresh capture
        // above independently revalidates ownership, mode, flags, and emptiness.
        guard publishedPolicy.extendedAttributes == policy.extendedAttributes else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        try validatePublishedFile(prepared.artifact, plan: plan)
    }

    static func indeterminateStagingCreation(
        destination: WorkspaceFileSystemLocation,
        stagingLocation: WorkspaceFileSystemLocation,
        reason: WorkspaceItemMutationFailure,
        expectedArtifact: WorkspacePreparedItemCreationArtifact?
    ) -> WorkspaceItemCreationOutcome {
        let state = stagingRecoveryState(
            at: stagingLocation,
            expecting: expectedArtifact?.expectation
        )
        return .creationStateIndeterminate(.init(
            destination: destination,
            reason: reason,
            recoveryState: state.state,
            createdExpectation: expectedArtifact?.expectation,
            recoveryExpectation: state.expectation,
            publicationSource: stagingLocation,
            actualPublishedExpectation: nil
        ))
    }

    static func provenExpectedPublication(
        _ artifact: WorkspacePreparedItemCreationArtifact,
        destination: WorkspaceFileSystemLocation
    ) -> WorkspaceItemMutationExpectation? {
        guard (try? WorkspaceNoFollowItemInspector.inspectExact(at: destination))
            == artifact.expectation
        else {
            return nil
        }
        return artifact.expectation
    }

    static func indeterminatePreparedCreation(
        _ artifact: WorkspacePreparedItemCreationArtifact,
        plan: WorkspaceItemCreationPlan,
        reason: WorkspaceItemMutationFailure,
        actualPublishedExpectation: WorkspaceItemMutationExpectation?
    ) -> WorkspaceItemCreationOutcome {
        let state = stagingRecoveryState(
            at: artifact.location,
            expecting: artifact.expectation
        )
        return .creationStateIndeterminate(.init(
            destination: plan.destination,
            reason: reason,
            recoveryState: state.state,
            createdExpectation: artifact.expectation,
            recoveryExpectation: state.expectation,
            publicationSource: artifact.location,
            actualPublishedExpectation: actualPublishedExpectation
        ))
    }

    static func stagingRecoveryState(
        at location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation?
    ) -> (
        state: WorkspaceItemCreationRecoveryState,
        expectation: WorkspaceItemMutationExpectation?
    ) {
        do {
            let actual = try WorkspaceNoFollowItemInspector.inspectExact(at: location)
            guard let expectation, actual == expectation else {
                return (.unknown, nil)
            }
            return (.retained(location), expectation)
        } catch WorkspaceAnchoredFileSystemError.missing {
            return (.none, nil)
        } catch {
            return (.unknown, nil)
        }
    }

    static func filePublicationHooks(
        _ hooks: WorkspaceAnchoredFileSystem.Hooks
    ) -> WorkspaceItemMutationHooks {
        WorkspaceItemMutationHooks(
            eventHandler: { event in
                switch event {
                case .willRename:
                    hooks.emit(.willCommit(.exclusiveCreate))
                case .didRename:
                    hooks.emit(.didCommit(.exclusiveCreate))
                case .willPrepareCommit, .willSyncDestinationParent, .willSyncSourceParent:
                    break
                }
            },
            injectedFailure: { event in
                let call: WorkspaceAnchoredFileSystem.InjectedCall? = switch event {
                case .willRename:
                    .renameExclusive
                case .willPrepareCommit:
                    .afterRenameExclusive
                case .willSyncDestinationParent:
                    .syncCommittedDirectory
                case .willSyncSourceParent:
                    .syncCleanupDirectory
                case .didRename:
                    nil
                }
                guard let call else { return nil }
                do {
                    try hooks.check(call)
                    return nil
                } catch {
                    return creationFailure(for: error)
                }
            }
        )
    }

    static func directoryPublicationHooks(
        _ hooks: WorkspaceItemCreationHooks
    ) -> WorkspaceItemMutationHooks {
        WorkspaceItemMutationHooks(eventHandler: { event in
            switch event {
            case .willRename:
                hooks.emit(.willCreate)
            case .didRename:
                hooks.emit(.didCreateName)
            case .willSyncDestinationParent:
                hooks.emit(.willSyncParent)
            case .willPrepareCommit, .willSyncSourceParent:
                break
            }
        })
    }

    // swiftlint:disable:next function_body_length
    static func cloneTrustedEmptyDirectory(
        to destination: WorkspaceFileSystemLocation,
        hooks: WorkspaceItemCreationHooks
    ) throws -> WorkspaceDirectoryCloneResult {
        let device = destination.rootAuthority.physicalIdentity.device
        return try WorkspaceDirectoryCloneSourceRegistry.shared.withSource(
            for: device,
            create: {
                try WorkspaceDirectoryCloneSourceSupport.makeUnlinkedSource(
                    appropriateFor: destination,
                    hooks: hooks
                )
            },
            validate: { source in
                try WorkspaceDirectoryCloneSourceSupport.validateUnlinkedSource(
                    source,
                    expectedDevice: device
                )
            }
            // swiftlint:disable:next multiple_closures_with_trailing_closure
        ) { source in
            try destination.rootAuthority.withRetainedRootDescriptor { rootDescriptor in
                var rootStatus = stat()
                guard Darwin.fstat(rootDescriptor, &rootStatus) == 0 else {
                    throw WorkspaceItemMutationFailure.unreadable
                }
                guard UInt64(rootStatus.st_dev) == device else {
                    throw WorkspaceItemMutationFailure.crossDevice
                }

                let flags = UInt32(CLONE_NOFOLLOW_ANY | CLONE_NOOWNERCOPY)
                hooks.emit(.willCloneDirectorySource(source.descriptor))
                try WorkspaceDirectoryCloneSourceSupport.validateUnlinkedSource(
                    source,
                    expectedDevice: device
                )
                let result = destination.relativePath.withCString {
                    Darwin.fclonefileat(
                        source.descriptor,
                        rootDescriptor,
                        $0,
                        flags
                    )
                }
                guard result == 0 else {
                    throw containedCreationFailure(errno)
                }
            }
            let sourceRemainedExact: Bool
            do {
                try WorkspaceDirectoryCloneSourceSupport.validateUnlinkedSource(
                    source,
                    expectedDevice: device
                )
                sourceRemainedExact = true
            } catch {
                sourceRemainedExact = false
            }
            return WorkspaceDirectoryCloneResult(
                sourceRemainedExact: sourceRemainedExact
            )
        }
    }

    static func openContainedDirectory(
        at location: WorkspaceFileSystemLocation
    ) throws -> Int32 {
        let descriptor = location.rootAuthority.withRetainedRootDescriptor { rootDescriptor in
            location.relativePath.withCString {
                Darwin.openat(
                    rootDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
                )
            }
        }
        guard descriptor >= 0 else {
            throw containedCreationFailure(errno)
        }
        return descriptor
    }

    static func directoryEntryIdentity(
        descriptor: Int32
    ) throws -> WorkspaceAnchoredFileSystem.DirectoryEntryIdentity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw WorkspaceItemMutationFailure.unreadable
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }
        return WorkspaceAnchoredFileSystem.DirectoryEntryIdentity(
            identity: WorkspaceFileSystemIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            ),
            fileType: status.st_mode & S_IFMT
        )
    }

    static func containedCreationFailure(
        _ errorNumber: Int32
    ) -> WorkspaceItemMutationFailure {
        switch errorNumber {
        case EEXIST, ENOTEMPTY:
            .destinationExists
        case ENOENT, ENOTDIR, ELOOP:
            .destinationChanged
        case EXDEV:
            .crossDevice
        default:
            .unreadable
        }
    }

    static func creationFailure(for error: Error) -> WorkspaceItemMutationFailure {
        if let failure = error as? WorkspaceItemMutationFailure {
            return failure
        }
        guard let anchored = error as? WorkspaceAnchoredFileSystemError else {
            return .unreadable
        }
        return switch anchored {
        case .missing, .symbolicLink, .notRegularFile, .namespaceChanged, .unstable:
            .destinationChanged
        case .changedIdentity:
            .destinationExists
        case .durabilityFailed:
            .durabilityFailed
        case .cleanupFailed:
            .rollbackFailed
        case .cancelled:
            .cancelled
        case .unreadable, .changedContent:
            .unreadable
        }
    }
}
