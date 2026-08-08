#if DEBUG
    import Darwin
    import Foundation

    extension DebugEditorFindFixture {
        static func removeStaleFixtures(
            in fixturesRoot: URL,
            excluding currentIdentifier: String,
            fileManager: FileManager = .default,
            now: Date = Date(),
            cleanupBoundaryHandler:
            EditorFindFixtureCleanupHandler? = nil,
            workspaceRemover: ((URL) throws -> Void)? = nil
        ) throws {
            guard try validateFixturesRootIfPresent(
                fixturesRoot,
                fileManager: fileManager
            ) else {
                return
            }
            let candidates = try fileManager.contentsOfDirectory(
                at: fixturesRoot,
                includingPropertiesForKeys: nil,
                options: []
            )
            let staleBefore = now.addingTimeInterval(-staleFixtureAge)
            guard let rootStatus = try entryStatus(at: fixturesRoot),
                  fileType(of: rootStatus) == mode_t(S_IFDIR)
            else {
                throw FixtureError.unsafeFixturesRoot
            }
            let rootHandle = try DebugEditorFindFixtureRootHandle(
                fixturesRoot: fixturesRoot,
                expectedIdentity: identity(of: rootStatus)
            )
            try removeOrphanedStaleLeases(
                from: candidates,
                in: fixturesRoot,
                excluding: currentIdentifier,
                staleBefore: staleBefore,
                rootHandle: rootHandle,
                cleanupBoundaryHandler: cleanupBoundaryHandler
            )

            for candidate in candidates {
                guard let stale = try validatedStaleCandidate(
                    candidate,
                    in: fixturesRoot,
                    excluding: currentIdentifier,
                    staleBefore: staleBefore,
                    rootHandle: rootHandle
                ),
                    let quarantineURL = try quarantineStaleCandidate(
                        stale,
                        in: fixturesRoot,
                        rootHandle: rootHandle,
                        cleanupBoundaryHandler: cleanupBoundaryHandler
                    )
                else {
                    continue
                }
                try removeProvenStaleQuarantine(
                    quarantineURL,
                    stale: stale,
                    rootHandle: rootHandle,
                    cleanupBoundaryHandler: cleanupBoundaryHandler,
                    workspaceRemover: workspaceRemover
                )
            }
        }

        private struct StaleCandidate {
            let identifier: String
            let sourceURL: URL
            let isPublished: Bool
            let lease: DebugEditorFindFixtureLease
            let workspaceHandle: DebugEditorFindFixtureWorkspaceHandle
        }

        private static func validatedStaleCandidate(
            _ candidate: URL,
            in fixturesRoot: URL,
            excluding currentIdentifier: String,
            staleBefore: Date,
            rootHandle: DebugEditorFindFixtureRootHandle
        ) throws -> StaleCandidate? {
            try rootHandle.validatePath()
            let candidateName = candidate.lastPathComponent
            let publishedIdentifier =
                (try? validatedIdentifier(candidateName)) == candidateName
                    ? candidateName
                    : nil
            guard let identifier = publishedIdentifier
                ?? quarantinedFixtureIdentifier(from: candidateName),
                identifier != currentIdentifier,
                let candidateStatus = try entryStatus(at: candidate),
                fileType(of: candidateStatus) == mode_t(S_IFDIR),
                modificationDate(of: candidateStatus) <= staleBefore
            else {
                return nil
            }
            let candidateIdentity = identity(of: candidateStatus)
            let leaseURL = ownershipLeaseURL(
                for: identifier,
                in: fixturesRoot
            )
            guard let lease = try DebugEditorFindFixtureLease
                .tryAcquireExisting(
                    at: leaseURL,
                    rootHandle: rootHandle
                ),
                let revalidatedStatus = try entryStatus(at: candidate),
                fileType(of: revalidatedStatus) == mode_t(S_IFDIR),
                identity(of: revalidatedStatus) == candidateIdentity
            else {
                // A locked lease belongs to a live or paused run. Missing or legacy
                // leases are preserved because ownership cannot be proven.
                return nil
            }
            try rootHandle.validatePath()
            try lease.validatePath()
            let binding: DebugEditorFindFixtureLease.WorkspaceBinding
            do {
                guard let persistedBinding = try lease.workspaceBinding() else {
                    return nil
                }
                binding = persistedBinding
            } catch {
                return nil
            }
            guard (try? binding.matchesWorkspace(at: candidate)) == true,
                  let workspaceHandle = try? DebugEditorFindFixtureWorkspaceHandle
                  .reopen(at: candidate, binding: binding)
            else {
                // Missing, corrupt, or mismatched ownership metadata fails closed.
                return nil
            }
            try rootHandle.validatePath()
            try workspaceHandle.validatePath(at: candidate)
            return StaleCandidate(
                identifier: identifier,
                sourceURL: candidate,
                isPublished: publishedIdentifier != nil,
                lease: lease,
                workspaceHandle: workspaceHandle
            )
        }

        private static func quarantineStaleCandidate(
            _ stale: StaleCandidate,
            in fixturesRoot: URL,
            rootHandle: DebugEditorFindFixtureRootHandle,
            cleanupBoundaryHandler: EditorFindFixtureCleanupHandler?
        ) throws -> URL? {
            guard stale.isPublished else {
                return stale.sourceURL
            }
            let quarantineURL = try makeQuarantineURL(
                for: stale.identifier,
                in: fixturesRoot
            )
            try cleanupBoundaryHandler?(
                .willQuarantine(
                    source: stale.sourceURL,
                    destination: quarantineURL
                )
            )
            try rootHandle.quarantine(
                source: stale.sourceURL,
                destination: quarantineURL
            )
            guard (try? stale.workspaceHandle.validatePath(
                at: quarantineURL
            )) != nil else {
                // The exclusive rename captured a same-name replacement. Preserve
                // that unproven quarantine and the exact ownership lease.
                return nil
            }
            try cleanupBoundaryHandler?(
                .didQuarantine(
                    source: stale.sourceURL,
                    destination: quarantineURL
                )
            )
            return quarantineURL
        }

        private static func removeProvenStaleQuarantine(
            _ quarantineURL: URL,
            stale: StaleCandidate,
            rootHandle: DebugEditorFindFixtureRootHandle,
            cleanupBoundaryHandler: EditorFindFixtureCleanupHandler?,
            workspaceRemover: ((URL) throws -> Void)?
        ) throws {
            do {
                try rootHandle.validatePath()
                try stale.workspaceHandle.validatePath(at: quarantineURL)
                try cleanupBoundaryHandler?(
                    .willRemoveQuarantine(quarantineURL)
                )
                try rootHandle.validatePath()
                try stale.workspaceHandle.validatePath(at: quarantineURL)
                try cleanupBoundaryHandler?(
                    .didValidateQuarantineForRemoval(quarantineURL)
                )
                if let workspaceRemover {
                    try workspaceRemover(quarantineURL)
                } else {
                    try stale.workspaceHandle.removeAnchored(
                        at: quarantineURL,
                        rootHandle: rootHandle,
                        cleanupBoundaryHandler: cleanupBoundaryHandler
                    )
                }
                guard try entryMode(at: quarantineURL) == nil else {
                    throw FixtureError.fixtureRemovalDidNotComplete
                }
                try stale.workspaceHandle.verifyRemoved()
            } catch {
                try reconcileStaleWorkspaceRemovalAfterFailure(
                    error,
                    quarantineURL: quarantineURL,
                    stale: stale,
                    rootHandle: rootHandle
                )
            }
            guard try stale.lease.linkCount() == 1 else {
                throw FixtureError.fixtureRemovalDidNotComplete
            }
            try stale.lease.unlinkPathIfStillOwned(
                cleanupBoundaryHandler: cleanupBoundaryHandler
            )
        }

        private static func reconcileStaleWorkspaceRemovalAfterFailure(
            _ originalError: Error,
            quarantineURL: URL,
            stale: StaleCandidate,
            rootHandle: DebugEditorFindFixtureRootHandle
        ) throws {
            if try entryMode(at: quarantineURL) != nil,
               (try? stale.workspaceHandle
                   .canResumeAfterOwnershipMarkerUnlink(
                       at: quarantineURL
                   )) == true
            {
                try stale.workspaceHandle.removeAnchored(
                    at: quarantineURL,
                    rootHandle: rootHandle
                )
                guard try entryMode(at: quarantineURL) == nil else {
                    throw FixtureError.fixtureRemovalDidNotComplete
                }
                try stale.workspaceHandle.verifyRemoved()
                return
            }
            guard try entryMode(at: quarantineURL) == nil,
                  (try? stale.workspaceHandle.verifyRemoved()) != nil
            else {
                throw originalError
            }
        }

        private static func removeOrphanedStaleLeases(
            from candidates: [URL],
            in fixturesRoot: URL,
            excluding currentIdentifier: String,
            staleBefore: Date,
            rootHandle: DebugEditorFindFixtureRootHandle,
            cleanupBoundaryHandler: EditorFindFixtureCleanupHandler?
        ) throws {
            for leaseURL in candidates {
                try rootHandle.validatePath()
                let leaseName = leaseURL.lastPathComponent
                let quarantinedIdentifier = quarantinedLeaseIdentifier(
                    from: leaseName
                )
                let publishedIdentifier: String? = {
                    guard quarantinedIdentifier == nil,
                          leaseName.hasPrefix(leaseFilePrefix)
                    else { return nil }
                    return String(leaseName.dropFirst(leaseFilePrefix.count))
                }()
                guard let identifier = quarantinedIdentifier
                    ?? publishedIdentifier
                else { continue }
                guard identifier != currentIdentifier,
                      (try? validatedIdentifier(identifier)) == identifier,
                      let leaseStatus = try entryStatus(at: leaseURL),
                      fileType(of: leaseStatus) == mode_t(S_IFREG),
                      modificationDate(of: leaseStatus) <= staleBefore
                else {
                    continue
                }
                let capturedLeaseIdentity = identity(of: leaseStatus)
                try cleanupBoundaryHandler?(
                    .didInspectOrphanLease(leaseURL)
                )
                let workspaceURL = fixturesRoot.appendingPathComponent(
                    identifier,
                    isDirectory: true
                )
                let publishedLeaseURL = ownershipLeaseURL(
                    for: identifier,
                    in: fixturesRoot
                )
                let hasCapturedWorkspaceEntry = candidates.contains { candidate in
                    candidate.lastPathComponent == identifier
                        || quarantinedFixtureIdentifier(
                            from: candidate.lastPathComponent
                        ) == identifier
                }
                guard try entryMode(at: workspaceURL) == nil,
                      try quarantinedIdentifier == nil
                      || (!hasCapturedWorkspaceEntry
                          && entryMode(at: publishedLeaseURL) == nil),
                      let lease = try DebugEditorFindFixtureLease
                      .tryAcquireExisting(
                          at: leaseURL,
                          publishedLeaseURL: publishedLeaseURL,
                          expectedIdentity: capturedLeaseIdentity,
                          rootHandle: rootHandle
                      )
                else {
                    continue
                }
                try lease.validatePath()
                let binding: DebugEditorFindFixtureLease.WorkspaceBinding?
                do {
                    binding = try lease.workspaceBinding()
                } catch {
                    // A corrupt or bound orphan may represent a renamed fixture.
                    // Preserve it rather than erasing the remaining ownership proof.
                    continue
                }
                guard quarantinedIdentifier != nil || binding == nil else {
                    continue
                }
                guard try entryMode(at: workspaceURL) == nil else {
                    continue
                }
                try rootHandle.validatePath()
                try lease.unlinkPathIfStillOwned(
                    cleanupBoundaryHandler: cleanupBoundaryHandler
                )
            }
        }

        private static func modificationDate(
            of status: stat
        ) -> Date {
            Date(
                timeIntervalSince1970:
                TimeInterval(status.st_mtimespec.tv_sec)
                    + TimeInterval(status.st_mtimespec.tv_nsec)
                    / 1_000_000_000
            )
        }
    }
#endif
