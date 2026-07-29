#if DEBUG
    import Darwin
    import Foundation

    extension DebugEditorFindFixture {
        static func removeStaleFixtures(
            in fixturesRoot: URL,
            excluding currentIdentifier: String,
            fileManager: FileManager = .default,
            now: Date = Date()
        ) throws {
            guard try validateFixturesRootIfPresent(
                fixturesRoot,
                fileManager: fileManager
            ) else {
                return
            }
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
            let candidates = try fileManager.contentsOfDirectory(
                at: fixturesRoot,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            let staleBefore = now.addingTimeInterval(-staleFixtureAge)
            try removeOrphanedStaleLeases(
                from: candidates,
                in: fixturesRoot,
                excluding: currentIdentifier,
                staleBefore: staleBefore
            )

            for candidate in candidates {
                guard candidate.lastPathComponent.hasPrefix(identifierPrefix),
                      candidate.lastPathComponent != currentIdentifier
                else {
                    continue
                }
                guard let candidateStatus = try entryStatus(at: candidate),
                      fileType(of: candidateStatus) == mode_t(S_IFDIR)
                else {
                    continue
                }
                let candidateIdentity = identity(of: candidateStatus)
                let values = try candidate.resourceValues(forKeys: keys)
                guard let modificationDate = values.contentModificationDate,
                      modificationDate <= staleBefore
                else {
                    continue
                }

                let leaseURL = ownershipLeaseURL(
                    for: candidate.lastPathComponent,
                    in: fixturesRoot
                )
                guard let lease = try DebugEditorFindFixtureLease
                    .tryAcquireExisting(at: leaseURL)
                else {
                    // A locked lease belongs to a live or paused run. Missing or legacy
                    // leases are preserved because ownership cannot be proven.
                    continue
                }
                guard let revalidatedStatus = try entryStatus(at: candidate),
                      fileType(of: revalidatedStatus) == mode_t(S_IFDIR),
                      identity(of: revalidatedStatus) == candidateIdentity
                else {
                    continue
                }
                try lease.validatePath()
                let binding: DebugEditorFindFixtureLease.WorkspaceBinding
                do {
                    guard let persistedBinding =
                        try lease.workspaceBinding()
                    else {
                        // A directory without a persisted workspace/marker binding
                        // cannot inherit deletion authority from a lexical lease name.
                        continue
                    }
                    binding = persistedBinding
                } catch {
                    // Corrupt or unreadable ownership metadata fails closed.
                    continue
                }
                guard (try? binding.matchesWorkspace(at: candidate)) == true
                else {
                    continue
                }
                guard let finalStatus = try entryStatus(at: candidate),
                      fileType(of: finalStatus) == mode_t(S_IFDIR),
                      identity(of: finalStatus) == candidateIdentity,
                      (try? binding.matchesWorkspace(at: candidate)) == true
                else {
                    continue
                }
                try fileManager.removeItem(at: candidate)
                guard try entryMode(at: candidate) == nil,
                      try lease.linkCount() == 1
                else {
                    throw FixtureError.fixtureRemovalDidNotComplete
                }
                try lease.unlinkPathIfStillOwned()
            }
        }

        private static func removeOrphanedStaleLeases(
            from candidates: [URL],
            in fixturesRoot: URL,
            excluding currentIdentifier: String,
            staleBefore: Date
        ) throws {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
            for leaseURL in candidates {
                let leaseName = leaseURL.lastPathComponent
                guard leaseName.hasPrefix(leaseFilePrefix) else {
                    continue
                }
                let identifier = String(leaseName.dropFirst(leaseFilePrefix.count))
                guard identifier != currentIdentifier,
                      (try? validatedIdentifier(identifier)) == identifier,
                      let leaseStatus = try entryStatus(at: leaseURL),
                      fileType(of: leaseStatus) == mode_t(S_IFREG),
                      let modificationDate = try leaseURL
                      .resourceValues(forKeys: keys)
                      .contentModificationDate,
                      modificationDate <= staleBefore
                else {
                    continue
                }
                let workspaceURL = fixturesRoot.appendingPathComponent(
                    identifier,
                    isDirectory: true
                )
                guard try entryMode(at: workspaceURL) == nil,
                      let lease = try DebugEditorFindFixtureLease
                      .tryAcquireExisting(at: leaseURL)
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
                guard binding == nil else {
                    continue
                }
                guard try entryMode(at: workspaceURL) == nil else {
                    continue
                }
                try lease.unlinkPathIfStillOwned()
            }
        }
    }
#endif
