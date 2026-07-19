import Foundation
import WorkspaceKit

enum WorkspaceMutationExactExpectationState: Equatable {
    case expected
    case missing
    case different
    case indeterminate
}

@MainActor
extension AppState {
    func reconcileUnexpectedRelocationEntryIfNeeded(
        _ context: WorkspaceRelocationRecoveryContext
    ) throws -> WorkspaceRelocationRecoveryContext {
        // A legacy/unknown journal cannot authorize any recovery mutation. An unexpected
        // moved identity can only precede the nonthrowing App commit, so it is likewise never
        // safe to reverse from a committed cleanup record.
        guard context.sessionCommitState == .pending,
              let actualExpectation = context.actualMovedExpectation,
              actualExpectation != context.expectation
        else {
            return context
        }

        let resolved = try resolveRelocationAuthorities(context)
        let context = resolved.context

        if unexpectedRelocationEntryIsRestored(
            context,
            actualExpectation: actualExpectation
        ) {
            return try clearUnexpectedRelocationExpectation(context)
        }
        // Do not automatically reverse an unexpected identity. Even with fixed parent
        // authorities, Darwin's rename syscall addresses the final leaf by name: a racer can
        // displace the inspected identity at `.willRename` and substitute another one. A second
        // recovery move would then create a new unjournaled identity. Keep both recorded slots
        // quarantined until the unexpected identity is independently restored or the user takes
        // an explicit recovery escape action.
        throw WorkspaceMutationError.indeterminateOperation(
            context.destination.fileURL,
            context.reason
        )
    }

    struct ResolvedRelocationAuthorities {
        var context: WorkspaceRelocationRecoveryContext
        let sourceParentResolvedFromBookmark: Bool
        let destinationParentResolvedFromBookmark: Bool
    }

    enum RelocationAuthoritySlot: Equatable {
        case source
        case destination
        case relocatedItem
    }

    struct RelocationEntryAuthority {
        let slot: RelocationAuthoritySlot
        let location: WorkspaceFileSystemLocation
        let parentExpectation: WorkspaceItemMutationExpectation
        let resolvedFromBookmark: Bool
    }

    struct RelocationTargetEntry {
        let location: WorkspaceFileSystemLocation
        let parentExpectation: WorkspaceItemMutationExpectation
        let leafName: String
    }

    func resolveRelocationAuthorities(
        _ context: WorkspaceRelocationRecoveryContext
    ) throws -> ResolvedRelocationAuthorities {
        guard let record = workspaceMutationOperationRecoveryRecords[context.id] else {
            return ResolvedRelocationAuthorities(
                context: context,
                sourceParentResolvedFromBookmark: false,
                destinationParentResolvedFromBookmark: false
            )
        }
        let restoredSource = restoredRelocationSourceParentAuthority(from: record)
        let restoredDestination = restoredRelocationDestinationParentAuthority(from: record)
        let restoredItem = restoredRelocationItemAuthority(from: record)
        var updated = context

        updated.sourceParentAuthorityLocation = restoredSource.location ??
            revalidatedRetainedRelocationParentLocation(
                context.sourceParentAuthorityLocation,
                expecting: context.sourceParentAuthorityExpectation
            )
        updated.destinationParentAuthorityLocation = restoredDestination.location ??
            revalidatedRetainedRelocationParentLocation(
                context.destinationParentAuthorityLocation,
                expecting: context.destinationParentAuthorityExpectation
            )
        updated.relocatedItemAuthorityLocation = restoredItem.location ??
            revalidatedRetainedRelocationItemLocation(
                context.relocatedItemAuthorityLocation,
                expecting: context.expectation
            )
        if let bookmarkData = restoredSource.refreshedBookmarkData {
            updated.sourceParentBookmarkData = bookmarkData
        }
        if let displayURL = restoredSource.displayURL {
            updated.sourceParentDisplayURL = displayURL
        }
        if let bookmarkData = restoredDestination.refreshedBookmarkData {
            updated.destinationParentBookmarkData = bookmarkData
        }
        if let displayURL = restoredDestination.displayURL {
            updated.destinationParentDisplayURL = displayURL
        }
        if let bookmarkData = restoredItem.refreshedBookmarkData {
            updated.relocatedItemBookmarkData = bookmarkData
        }
        if let displayURL = restoredItem.displayURL {
            updated.relocatedItemDisplayURL = displayURL
        }

        let durableAuthorityChanged =
            updated.sourceParentBookmarkData != context.sourceParentBookmarkData ||
            updated.sourceParentDisplayURL != context.sourceParentDisplayURL ||
            updated.destinationParentBookmarkData != context.destinationParentBookmarkData ||
            updated.destinationParentDisplayURL != context.destinationParentDisplayURL ||
            updated.relocatedItemBookmarkData != context.relocatedItemBookmarkData ||
            updated.relocatedItemDisplayURL != context.relocatedItemDisplayURL
        if durableAuthorityChanged {
            try persistWorkspaceMutationRecoveryUpdate(.relocation(updated))
        } else {
            workspaceMutationRecoveries[updated.id] = .relocation(updated)
        }
        return ResolvedRelocationAuthorities(
            context: updated,
            sourceParentResolvedFromBookmark: restoredSource.location != nil,
            destinationParentResolvedFromBookmark: restoredDestination.location != nil
        )
    }

    func restoreEscapedRelocationEntryIfNeeded(
        _ installedContext: WorkspaceRelocationRecoveryContext
    ) throws -> WorkspaceRelocationRecoveryContext {
        guard installedContext.sessionCommitState != .unknown,
              installedContext.actualMovedExpectation == nil ||
              installedContext.actualMovedExpectation == installedContext.expectation
        else {
            return installedContext
        }
        let resolved = try resolveRelocationAuthorities(installedContext)
        var context = resolved.context
        if workspaceRelocationPhaseTargetIsProven(context) {
            if context.actualMovedExpectation != nil {
                context.actualMovedExpectation = nil
                try persistWorkspaceMutationRecoveryUpdate(.relocation(context))
            }
            return context
        }
        guard let target = workspaceRelocationTargetEntry(context),
              workspaceMutationExactExpectationState(
                  at: target.location,
                  expecting: context.expectation,
                  parentExpectation: target.parentExpectation
              ) == .missing
        else {
            return context
        }

        let containingAuthorities = relocationEntryAuthorities(
            resolved,
            expecting: context.expectation,
            requiringBookmarkResolution: true
        )
        guard containingAuthorities.count == 1,
              let current = containingAuthorities.first
        else {
            return context
        }
        guard let destination = relocationEntryAuthorities(resolved).first(where: {
            $0.resolvedFromBookmark &&
                relocationAuthority($0, matches: target)
        }), destination.slot != current.slot else {
            return context
        }

        let outcome = WorkspaceAnchoredItemMutator.restoreIndeterminateRelocation(
            from: current.location,
            to: target.location,
            expecting: context.expectation,
            sourceParentExpectation: current.parentExpectation,
            destinationParentExpectation: destination.parentExpectation
        )
        switch outcome {
        case .movedAndDurable:
            // Re-resolve the durable item authority after the recovery rename. Reusing the
            // pre-move runtime location would make this Check Again pass prove the old escaped
            // slot even though the retained bookmark now follows the inode back to `target`.
            context = try resolveRelocationAuthorities(resolved.context).context
            if context.actualMovedExpectation != nil {
                context.actualMovedExpectation = nil
                try persistWorkspaceMutationRecoveryUpdate(.relocation(context))
            }
            return context
        case let .notMoved(failure):
            context = resolved.context
            context.reason = failure
            try persistWorkspaceMutationRecoveryUpdate(.relocation(context))
        case let .movedButIndeterminate(indeterminate):
            context = resolved.context
            context.reason = indeterminate.reason
            context.actualMovedExpectation = indeterminate.actualMovedExpectation
            try persistWorkspaceMutationRecoveryUpdate(.relocation(context))
        }
        throw WorkspaceMutationError.indeterminateOperation(
            target.location.fileURL,
            context.reason
        )
    }

    func workspaceRelocationPhaseTargetIsProven(
        _ context: WorkspaceRelocationRecoveryContext
    ) -> Bool {
        guard context.actualMovedExpectation == nil ||
            context.actualMovedExpectation == context.expectation
        else {
            return false
        }
        for _ in 0 ..< 2 {
            guard let target = workspaceRelocationTargetEntry(context),
                  workspaceMutationExactExpectationState(
                      at: target.location,
                      expecting: context.expectation,
                      parentExpectation: target.parentExpectation
                  ) == .expected
            else {
                return false
            }
            let authorities = relocationEntryAuthorities(
                ResolvedRelocationAuthorities(
                    context: context,
                    sourceParentResolvedFromBookmark: false,
                    destinationParentResolvedFromBookmark: false
                )
            )
            // Both durable parent-entry slots must remain inspectable before recovery is
            // released. A failed bookmark resolution may hide an escaped hard-link alias; it
            // is not evidence that the recorded slot is clear. A revalidated current-launch
            // retained location is sufficient for this proof, but an absent slot is not.
            guard authorities.count == 2,
                  authorities.contains(where: {
                      relocationAuthority($0, matches: target) &&
                          workspaceMutationExactExpectationState(
                              at: $0.location,
                              expecting: context.expectation,
                              parentExpectation: $0.parentExpectation
                          ) == .expected
                  }),
                  authorities.allSatisfy({
                      relocationAuthority($0, matches: target) ||
                          relocationExpectationStateIsClear(
                              workspaceMutationExactExpectationState(
                                  at: $0.location,
                                  expecting: context.expectation,
                                  parentExpectation: $0.parentExpectation
                              )
                          )
                  }),
                  workspaceRelocationOppositeLogicalEntryIsClear(
                      context,
                      target: target
                  ),
                  relocatedItemAuthorityMatchesPhaseTarget(
                      context,
                      target: target
                  )
            else {
                return false
            }
        }
        return true
    }

    func relocationExpectationStateIsClear(
        _ state: WorkspaceMutationExactExpectationState
    ) -> Bool {
        state == .missing || state == .different
    }

    func revalidatedRetainedRelocationParentLocation(
        _ location: WorkspaceFileSystemLocation?,
        expecting parentExpectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceFileSystemLocation? {
        guard let location,
              (try? WorkspaceNoFollowItemInspector.inspectParent(of: location)) ==
              parentExpectation
        else {
            return nil
        }
        return location
    }

    func revalidatedRetainedRelocationItemLocation(
        _ location: WorkspaceFileSystemLocation?,
        expecting expectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceFileSystemLocation? {
        guard let location,
              workspaceMutationExactExpectationState(
                  at: location,
                  expecting: expectation,
                  parentExpectation: nil
              ) == .expected
        else {
            return nil
        }
        return location
    }

    func relocationEntryAuthorities(
        _ resolved: ResolvedRelocationAuthorities,
        expecting expectation: WorkspaceItemMutationExpectation? = nil,
        requiringBookmarkResolution: Bool = false
    ) -> [RelocationEntryAuthority] {
        let context = resolved.context
        let candidates = [
            context.sourceParentAuthorityLocation.map {
                RelocationEntryAuthority(
                    slot: .source,
                    location: $0,
                    parentExpectation: context.sourceParentAuthorityExpectation,
                    resolvedFromBookmark: resolved.sourceParentResolvedFromBookmark
                )
            },
            context.destinationParentAuthorityLocation.map {
                RelocationEntryAuthority(
                    slot: .destination,
                    location: $0,
                    parentExpectation: context.destinationParentAuthorityExpectation,
                    resolvedFromBookmark: resolved.destinationParentResolvedFromBookmark
                )
            },
        ].compactMap { $0 }
        return candidates.filter { candidate in
            guard !requiringBookmarkResolution || candidate.resolvedFromBookmark else {
                return false
            }
            guard let expectation else { return true }
            return workspaceMutationExactExpectationState(
                at: candidate.location,
                expecting: expectation,
                parentExpectation: candidate.parentExpectation
            ) == .expected
        }
    }

    func relocatedItemAuthorityMatchesPhaseTarget(
        _ context: WorkspaceRelocationRecoveryContext,
        target: RelocationTargetEntry
    ) -> Bool {
        guard context.relocatedItemBookmarkData != nil ||
            context.relocatedItemAuthorityLocation != nil
        else {
            return true
        }
        guard let location = context.relocatedItemAuthorityLocation else {
            return false
        }
        let authority = RelocationEntryAuthority(
            slot: .relocatedItem,
            location: location,
            parentExpectation: location.rootAuthority.directoryMutationExpectation,
            resolvedFromBookmark: false
        )
        return relocationAuthority(authority, matches: target) &&
            workspaceMutationExactExpectationState(
                at: authority.location,
                expecting: context.expectation,
                parentExpectation: authority.parentExpectation
            ) == .expected
    }

    func workspaceRelocationTargetEntry(
        _ context: WorkspaceRelocationRecoveryContext
    ) -> RelocationTargetEntry? {
        let location: WorkspaceFileSystemLocation
        let parentExpectation: WorkspaceItemMutationExpectation
        switch context.sessionCommitState {
        case .unknown:
            return nil
        case .pending:
            location = context.source
            parentExpectation = context.sourceParentExpectation
        case .committed:
            location = context.destination
            parentExpectation = context.destinationParentExpectation
        }
        guard let leafName = exactRelativePathComponents(location.relativePath).last,
              (try? WorkspaceNoFollowItemInspector.inspectParent(of: location)) ==
              parentExpectation
        else {
            return nil
        }
        return RelocationTargetEntry(
            location: location,
            parentExpectation: parentExpectation,
            leafName: leafName
        )
    }

    func relocationAuthority(
        _ authority: RelocationEntryAuthority,
        matches target: RelocationTargetEntry
    ) -> Bool {
        authority.parentExpectation == target.parentExpectation &&
            authority.location.relativePath.utf8.elementsEqual(target.leafName.utf8)
    }

    func workspaceRelocationOppositeLogicalEntryIsClear(
        _ context: WorkspaceRelocationRecoveryContext,
        target _: RelocationTargetEntry
    ) -> Bool {
        let opposite: WorkspaceFileSystemLocation
        switch context.sessionCommitState {
        case .unknown:
            return false
        case .pending:
            opposite = context.destination
        case .committed:
            opposite = context.source
        }
        let state = workspaceMutationExactExpectationState(
            at: opposite,
            expecting: context.expectation,
            parentExpectation: nil
        )
        return state == .missing || state == .different
    }

    func reconcileUnexpectedTrashStagingEntryIfNeeded(
        _ context: WorkspaceTrashRecoveryContext
    ) throws -> WorkspaceTrashRecoveryContext {
        guard let actualExpectation = context.actualStagedExpectation,
              actualExpectation != context.expectation,
              let stagingLocation = workspaceTrashStagingLocation(context),
              let recoveryTarget = context.actualStagedEntryRecoveryLocation
        else {
            return context
        }

        if unexpectedTrashEntryIsRestored(
            context,
            stagingLocation: stagingLocation,
            recoveryTarget: recoveryTarget,
            actualExpectation: actualExpectation
        ) {
            return try clearUnexpectedTrashExpectation(context)
        }
        // As with creation and relocation, never issue a second name-based rename for an
        // unexpected identity. Its current journaled slot remains the recovery authority.
        throw WorkspaceMutationError.indeterminateOperation(
            stagingLocation.fileURL,
            context.reason
        )
    }

    func restoreWorkspaceTrashRecoveryLocationIfPossible(
        _ context: WorkspaceTrashRecoveryContext
    ) throws -> Bool {
        guard context.sessionCommitState == .pending,
              let sourceAuthority = context.sourceParentAuthorityLocation,
              context.sourceParentBookmarkData != nil,
              context.sourceLeafName != nil,
              workspaceMutationExactEntryAddressMatches(
                  sourceAuthority,
                  context.source
              ),
              !context.expectedItemAuthorityIsUnresolved,
              let expectedItemAuthority = context.expectedItemAuthorityLocation,
              let recoveryLocation = context.recoveryLocation,
              workspaceMutationExactEntryAddressMatches(
                  expectedItemAuthority,
                  recoveryLocation
              ),
              workspaceMutationExactExpectationState(
                  at: expectedItemAuthority,
                  expecting: context.expectation,
                  parentExpectation: nil
              ) == .expected,
              workspaceMutationExactExpectationState(
                  at: context.source,
                  expecting: context.expectation,
                  parentExpectation: context.sourceParentExpectation
              ) == .missing,
              workspaceMutationExactExpectationState(
                  at: recoveryLocation,
                  expecting: context.expectation,
                  parentExpectation: nil
              ) == .expected
        else {
            return false
        }
        let recoveryParentExpectation = try WorkspaceNoFollowItemInspector.inspectParent(
            of: recoveryLocation
        )
        let outcome = WorkspaceAnchoredItemMutator.restoreIndeterminateRelocation(
            from: recoveryLocation,
            to: context.source,
            expecting: context.expectation,
            sourceParentExpectation: recoveryParentExpectation,
            destinationParentExpectation: context.sourceParentExpectation
        )

        return try reconcileWorkspaceTrashRecoveryRelocationOutcome(
            outcome,
            context: context,
            recoveryLocation: recoveryLocation
        )
    }

    func reconcileWorkspaceTrashRecoveryRelocationOutcome(
        _ outcome: WorkspaceItemMutationOutcome<Void>,
        context: WorkspaceTrashRecoveryContext,
        recoveryLocation: WorkspaceFileSystemLocation
    ) throws -> Bool {
        let resolvedContext = try resolveWorkspaceTrashAuthorities(context)
        if workspaceTrashSourceIsSoleExpectedLocation(resolvedContext) {
            return true
        }

        switch outcome {
        case .movedAndDurable:
            throw WorkspaceMutationError.indeterminateOperation(
                context.source.fileURL,
                context.reason
            )
        case let .movedButIndeterminate(indeterminate):
            if let actualExpectation = indeterminate.actualMovedExpectation,
               actualExpectation != resolvedContext.expectation
            {
                var updated = resolvedContext
                updated.actualStagedExpectation = actualExpectation
                updated.actualStagedEntryRecoveryLocation = recoveryLocation
                try persistWorkspaceMutationRecoveryUpdate(.trash(updated))
            }
            throw WorkspaceMutationError.indeterminateOperation(
                resolvedContext.source.fileURL,
                indeterminate.reason
            )
        case let .notMoved(reason):
            throw WorkspaceMutationError.indeterminateOperation(
                resolvedContext.source.fileURL,
                reason
            )
        }
    }

    func provenReportedTrashLocation(
        _ context: WorkspaceTrashRecoveryContext
    ) -> WorkspaceFileSystemLocation? {
        guard context.sessionCommitState == .committed,
              context.sourceParentBookmarkData != nil,
              let sourceAuthority = context.sourceParentAuthorityLocation,
              context.expectedItemBookmarkData != nil,
              !context.expectedItemAuthorityIsUnresolved,
              let expectedItemAuthority = context.expectedItemAuthorityLocation,
              context.reportedTrashBookmarkData != nil,
              let reportedLocation = context.reportedTrashAuthorityLocation,
              workspaceMutationExactEntryAddressMatches(
                  expectedItemAuthority,
                  reportedLocation
              )
        else {
            return nil
        }
        let otherCandidates = [
            context.source,
            sourceAuthority,
            context.recoveryLocation,
            context.stagingCleanupLocation,
            context.actualStagedEntryRecoveryLocation,
        ].compactMap { $0 }
        for _ in 0 ..< 2 {
            guard workspaceMutationExactExpectationState(
                at: reportedLocation,
                expecting: context.expectation,
                parentExpectation: nil
            ) == .expected,
                workspaceMutationExactExpectationState(
                    at: expectedItemAuthority,
                    expecting: context.expectation,
                    parentExpectation: nil
                ) == .expected,
                otherCandidates.allSatisfy({ candidate in
                    if workspaceMutationExactEntryAddressMatches(
                        candidate,
                        reportedLocation
                    ) {
                        return true
                    }
                    return relocationExpectationStateIsClear(
                        workspaceMutationExactExpectationState(
                            at: candidate,
                            expecting: context.expectation,
                            parentExpectation: candidate == sourceAuthority
                                ? context.sourceParentAuthorityExpectation
                                : nil
                        )
                    )
                })
            else {
                return nil
            }
        }
        return reportedLocation
    }

    func workspaceMutationExactExpectationState(
        at location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation,
        parentExpectation: WorkspaceItemMutationExpectation?
    ) -> WorkspaceMutationExactExpectationState {
        if let parentExpectation {
            do {
                guard try WorkspaceNoFollowItemInspector.inspectParent(
                    of: location
                ) == parentExpectation else {
                    return .indeterminate
                }
            } catch {
                return .indeterminate
            }
        }
        do {
            return try WorkspaceNoFollowItemInspector.inspectExact(at: location) == expectation
                ? .expected
                : .different
        } catch WorkspaceAnchoredFileSystemError.missing {
            return .missing
        } catch {
            return .indeterminate
        }
    }
}

@MainActor
extension AppState {
    func workspaceTrashSourceIsSoleExpectedLocation(
        _ context: WorkspaceTrashRecoveryContext
    ) -> Bool {
        workspaceTrashSourceIsSoleExpectedLocationImpl(context)
    }
}

@MainActor
private extension AppState {
    func unexpectedRelocationEntryIsRestored(
        _ context: WorkspaceRelocationRecoveryContext,
        actualExpectation: WorkspaceItemMutationExpectation
    ) -> Bool {
        let destinationState = workspaceMutationExactExpectationState(
            at: context.destination,
            expecting: actualExpectation,
            parentExpectation: context.destinationParentExpectation
        )
        return workspaceMutationExactExpectationState(
            at: context.source,
            expecting: actualExpectation,
            parentExpectation: context.sourceParentExpectation
        ) == .expected &&
            (destinationState == .missing || destinationState == .different)
    }

    func clearUnexpectedRelocationExpectation(
        _ context: WorkspaceRelocationRecoveryContext
    ) throws -> WorkspaceRelocationRecoveryContext {
        var updated = context
        updated.actualMovedExpectation = nil
        try persistWorkspaceMutationRecoveryUpdate(.relocation(updated))
        return updated
    }

    func workspaceTrashStagingLocation(
        _ context: WorkspaceTrashRecoveryContext
    ) -> WorkspaceFileSystemLocation? {
        if case let .removalIndeterminate(location) = context.cleanupState {
            return location
        }
        return context.recoveryLocation
    }

    func unexpectedTrashEntryIsRestored(
        _ context: WorkspaceTrashRecoveryContext,
        stagingLocation: WorkspaceFileSystemLocation,
        recoveryTarget: WorkspaceFileSystemLocation,
        actualExpectation: WorkspaceItemMutationExpectation
    ) -> Bool {
        let otherLocation = recoveryTarget == context.source
            ? stagingLocation
            : context.source
        let otherState = workspaceMutationExactExpectationState(
            at: otherLocation,
            expecting: actualExpectation,
            parentExpectation: otherLocation == context.source
                ? context.sourceParentExpectation
                : nil
        )
        return workspaceMutationExactExpectationState(
            at: recoveryTarget,
            expecting: actualExpectation,
            parentExpectation: recoveryTarget == context.source
                ? context.sourceParentExpectation
                : nil
        ) == .expected &&
            (otherState == .missing || otherState == .different)
    }

    func clearUnexpectedTrashExpectation(
        _ context: WorkspaceTrashRecoveryContext
    ) throws -> WorkspaceTrashRecoveryContext {
        var updated = context
        updated.actualStagedExpectation = nil
        updated.actualStagedEntryRecoveryLocation = nil
        try persistWorkspaceMutationRecoveryUpdate(.trash(updated))
        return updated
    }

    func workspaceTrashExpectedRecoveryIsRestored(
        _ context: WorkspaceTrashRecoveryContext,
        recoveryLocation: WorkspaceFileSystemLocation
    ) -> Bool {
        let recoveryState = workspaceMutationExactExpectationState(
            at: recoveryLocation,
            expecting: context.expectation,
            parentExpectation: nil
        )
        return workspaceMutationExactExpectationState(
            at: context.source,
            expecting: context.expectation,
            parentExpectation: context.sourceParentExpectation
        ) == .expected &&
            (recoveryState == .missing || recoveryState == .different)
    }

    func workspaceTrashSourceIsSoleExpectedLocationImpl(
        _ context: WorkspaceTrashRecoveryContext
    ) -> Bool {
        guard context.sessionCommitState == .pending,
              context.sourceParentBookmarkData != nil,
              let sourceAuthority = context.sourceParentAuthorityLocation,
              context.expectedItemBookmarkData != nil,
              !context.expectedItemAuthorityIsUnresolved,
              let expectedItemAuthority = context.expectedItemAuthorityLocation,
              workspaceMutationExactEntryAddressMatches(
                  sourceAuthority,
                  context.source
              ),
              workspaceMutationExactEntryAddressMatches(
                  expectedItemAuthority,
                  context.source
              ),
              context.actualStagedExpectation == nil ||
              context.actualStagedExpectation == context.expectation
        else {
            return false
        }
        guard context.reportedTrashBookmarkData == nil ||
            context.reportedTrashAuthorityLocation != nil
        else {
            return false
        }
        let candidates = [
            context.recoveryLocation,
            context.stagingCleanupLocation,
            context.actualStagedEntryRecoveryLocation,
            context.reportedTrashAuthorityLocation,
        ].compactMap { $0 }
        for _ in 0 ..< 2 {
            guard workspaceMutationExactExpectationState(
                at: context.source,
                expecting: context.expectation,
                parentExpectation: context.sourceParentExpectation
            ) == .expected,
                workspaceMutationExactExpectationState(
                    at: sourceAuthority,
                    expecting: context.expectation,
                    parentExpectation: context.sourceParentAuthorityExpectation
                ) == .expected,
                workspaceMutationExactExpectationState(
                    at: expectedItemAuthority,
                    expecting: context.expectation,
                    parentExpectation: nil
                ) == .expected,
                candidates.allSatisfy({ candidate in
                    if workspaceMutationExactEntryAddressMatches(
                        candidate,
                        context.source
                    ) {
                        return true
                    }
                    return relocationExpectationStateIsClear(
                        workspaceMutationExactExpectationState(
                            at: candidate,
                            expecting: context.expectation,
                            parentExpectation: nil
                        )
                    )
                })
            else {
                return false
            }
        }
        return true
    }

    func workspaceMutationExactEntryAddressMatches(
        _ lhs: WorkspaceFileSystemLocation,
        _ rhs: WorkspaceFileSystemLocation
    ) -> Bool {
        guard let lhsLeaf = exactRelativePathComponents(lhs.relativePath).last,
              let rhsLeaf = exactRelativePathComponents(rhs.relativePath).last,
              lhsLeaf.utf8.elementsEqual(rhsLeaf.utf8),
              let lhsParent = try? WorkspaceNoFollowItemInspector.inspectParent(of: lhs),
              let rhsParent = try? WorkspaceNoFollowItemInspector.inspectParent(of: rhs)
        else {
            return false
        }
        return lhsParent == rhsParent
    }

    func workspaceTrashRecoveryLocationIsClear(
        _ context: WorkspaceTrashRecoveryContext
    ) -> Bool {
        guard let recoveryLocation = context.recoveryLocation else { return true }
        let state = workspaceMutationExactExpectationState(
            at: recoveryLocation,
            expecting: context.expectation,
            parentExpectation: nil
        )
        return state == .missing || state == .different
    }
}
