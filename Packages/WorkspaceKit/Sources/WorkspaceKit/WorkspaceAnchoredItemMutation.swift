import Darwin
import Foundation

/// The no-follow namespace kind of an item. Unlike `WorkspaceFileKind`, this describes the
/// directory entry itself, so a symbolic link is never classified from its target.
public enum WorkspaceFileSystemItemKind: Sendable, Hashable {
    case regularFile
    case directory
    case symbolicLink
    case other

    init(mode: mode_t) {
        switch mode & S_IFMT {
        case S_IFREG:
            self = .regularFile
        case S_IFDIR:
            self = .directory
        case S_IFLNK:
            self = .symbolicLink
        default:
            self = .other
        }
    }
}

/// The physical item that a UI snapshot authorized the caller to mutate.
public struct WorkspaceItemMutationExpectation: Sendable, Hashable {
    public let identity: WorkspaceFileSystemIdentity
    public let kind: WorkspaceFileSystemItemKind

    public init(identity: WorkspaceFileSystemIdentity, kind: WorkspaceFileSystemItemKind) {
        self.identity = identity
        self.kind = kind
    }
}

public enum WorkspaceItemMutationFailure: Error, Sendable, Equatable {
    case invalidName
    case differentRootAuthority
    case sourceMissing
    case sourceChanged
    case destinationChanged
    case destinationExists
    case destinationInsideSource
    case namespaceChanged
    case crossDevice
    case unreadable
    case commitPreparationFailed
    case durabilityFailed
    case recyclerFailed
    case rollbackFailed
    case cancelled
}

public struct WorkspaceItemRelocation: Sendable, Equatable {
    public let source: WorkspaceFileSystemLocation
    public let destination: WorkspaceFileSystemLocation
    public let expectation: WorkspaceItemMutationExpectation

    public init(
        source: WorkspaceFileSystemLocation,
        destination: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation
    ) {
        self.source = source
        self.destination = destination
        self.expectation = expectation
    }
}

public struct WorkspaceIndeterminateItemMutation<Prepared> {
    public let relocation: WorkspaceItemRelocation
    public let reason: WorkspaceItemMutationFailure
    public let preparedCommit: Prepared?
    public let actualMovedExpectation: WorkspaceItemMutationExpectation?

    public init(
        relocation: WorkspaceItemRelocation,
        reason: WorkspaceItemMutationFailure,
        preparedCommit: Prepared?,
        actualMovedExpectation: WorkspaceItemMutationExpectation? = nil
    ) {
        self.relocation = relocation
        self.reason = reason
        self.preparedCommit = preparedCommit
        self.actualMovedExpectation = actualMovedExpectation
    }
}

/// A relocation's filesystem result plus the caller-owned state prepared while the exact
/// destination entry existed. The caller commits that prepared value only for the durable case.
public enum WorkspaceItemMutationOutcome<Prepared> {
    case notMoved(WorkspaceItemMutationFailure)
    case movedAndDurable(relocation: WorkspaceItemRelocation, preparedCommit: Prepared)
    case movedButIndeterminate(WorkspaceIndeterminateItemMutation<Prepared>)
}

/// Captures one exact no-follow identity from a retained root-relative location.
public enum WorkspaceNoFollowItemInspector {
    public static func inspect(
        at location: WorkspaceFileSystemLocation
    ) throws -> WorkspaceItemMutationExpectation {
        try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
            try WorkspaceAnchoredFileSystem.withAnchoredParent(
                at: location,
                hooks: .production
            ) { chain, parentDescriptor, leaf in
                let entry = try WorkspaceAnchoredFileSystem.directoryEntryIdentity(
                    parentDescriptor: parentDescriptor,
                    component: leaf
                )
                try chain.validateNamespace()
                try WorkspaceAnchoredFileSystem.validateNameStillReferencesEntry(
                    parentDescriptor: parentDescriptor,
                    leaf: leaf,
                    entry: entry
                )
                try chain.validateNamespace()
                return entry.mutationExpectation
            }
        }
    }

    /// Captures only the directory entry whose literal UTF-8 spelling matches the retained
    /// location. Unlike a normal path lookup, this does not accept a case- or
    /// normalization-equivalent sibling on a case-insensitive filesystem.
    public static func inspectExact(
        at location: WorkspaceFileSystemLocation
    ) throws -> WorkspaceItemMutationExpectation {
        try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
            try WorkspaceAnchoredFileSystem.withAnchoredParent(
                at: location,
                hooks: .production
            ) { chain, parentDescriptor, leaf in
                guard let entry = try WorkspaceAnchoredFileSystem.exactDirectoryEntry(
                    parentDescriptor: parentDescriptor,
                    leaf: leaf
                ) else {
                    throw WorkspaceAnchoredFileSystemError.missing
                }
                try chain.validateNamespace()
                try WorkspaceAnchoredFileSystem.validateNameStillReferencesEntry(
                    parentDescriptor: parentDescriptor,
                    leaf: leaf,
                    entry: entry
                )
                try chain.validateNamespace()
                return entry.mutationExpectation
            }
        }
    }

    public static func inspectParent(
        of location: WorkspaceFileSystemLocation
    ) throws -> WorkspaceItemMutationExpectation {
        try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
            try WorkspaceAnchoredFileSystem.withAnchoredParent(
                at: location,
                hooks: .production
            ) { chain, parentDescriptor, _ in
                let identity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(
                    parentDescriptor
                )
                try chain.validateNamespace()
                return WorkspaceItemMutationExpectation(identity: identity, kind: .directory)
            }
        }
    }

    /// Returns the filesystem's name-comparison policy for the exact retained parent.
    public static func parentIsCaseSensitive(
        of location: WorkspaceFileSystemLocation
    ) throws -> Bool {
        try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
            try WorkspaceAnchoredFileSystem.withAnchoredParent(
                at: location,
                hooks: .production
            ) { chain, parentDescriptor, _ in
                let isCaseSensitive = try WorkspaceAnchoredFileSystem.directoryIsCaseSensitive(
                    parentDescriptor
                )
                try chain.validateNamespace()
                return isCaseSensitive
            }
        }
    }

    /// Returns the retained root directory's name-comparison policy. This is a fail-closed
    /// fallback for ownership reservations whose immediate parent no longer exists; the root
    /// descriptor remains authoritative even when no descendant path can be opened.
    public static func rootIsCaseSensitive(
        of location: WorkspaceFileSystemLocation
    ) throws -> Bool {
        try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: location) {
            try location.rootAuthority.withRetainedRootDescriptor { rootDescriptor in
                try WorkspaceAnchoredFileSystem.directoryIsCaseSensitive(rootDescriptor)
            }
        }
    }
}

enum WorkspaceItemMutationEvent: Equatable {
    case willRename
    case didRename
    case willPrepareCommit
    case willSyncDestinationParent
    case willSyncSourceParent
}

struct WorkspaceItemMutationHooks {
    static let production = WorkspaceItemMutationHooks()

    let eventHandler: (@Sendable (WorkspaceItemMutationEvent) -> Void)?
    let injectedFailure: (@Sendable (WorkspaceItemMutationEvent) -> WorkspaceItemMutationFailure?)?

    init(
        eventHandler: (@Sendable (WorkspaceItemMutationEvent) -> Void)? = nil,
        injectedFailure: (@Sendable (WorkspaceItemMutationEvent) -> WorkspaceItemMutationFailure?)? = nil
    ) {
        self.eventHandler = eventHandler
        self.injectedFailure = injectedFailure
    }

    func emit(_ event: WorkspaceItemMutationEvent) {
        eventHandler?(event)
    }

    func check(_ event: WorkspaceItemMutationEvent) throws {
        emit(event)
        if let failure = injectedFailure?(event) {
            throw failure
        }
    }
}

public enum WorkspaceAnchoredItemMutator {
    public static func relocate<Prepared>(
        _ source: WorkspaceFileSystemLocation,
        to destination: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        destinationParentExpectation: WorkspaceItemMutationExpectation,
        preparingCommit: (WorkspaceItemRelocation) throws -> Prepared
    ) -> WorkspaceItemMutationOutcome<Prepared> {
        relocate(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            preparingCommit: preparingCommit,
            hooks: .production
        )
    }

    static func relocate<Prepared>(
        _ source: WorkspaceFileSystemLocation,
        to destination: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        destinationParentExpectation: WorkspaceItemMutationExpectation,
        preparingCommit: (WorkspaceItemRelocation) throws -> Prepared,
        hooks: WorkspaceItemMutationHooks
    ) -> WorkspaceItemMutationOutcome<Prepared> {
        let relocation = WorkspaceItemRelocation(
            source: source,
            destination: destination,
            expectation: expectation
        )
        guard source.rootAuthority == destination.rootAuthority else {
            return .notMoved(.differentRootAuthority)
        }
        if expectation.kind == .directory,
           destination.relativePath.isByteExactDescendant(of: source.relativePath)
        {
            return .notMoved(.destinationInsideSource)
        }

        if source == destination {
            return prepareUnchangedRelocation(
                relocation,
                sourceParentExpectation: sourceParentExpectation,
                destinationParentExpectation: destinationParentExpectation,
                preparingCommit: preparingCommit
            )
        }

        return performRelocation(
            relocation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            preparingCommit: preparingCommit,
            hooks: hooks
        )
    }

    /// Restores an indeterminate relocation from an exact parent authority that was retained
    /// or freshly resolved by recovery. Unlike a forward relocation, this recovery-only path
    /// may cross root authorities, but it still requires the original item and both parents to
    /// match their captured identities and never replaces an occupied destination.
    public static func restoreIndeterminateRelocation(
        from retainedSource: WorkspaceFileSystemLocation,
        to workspaceDestination: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        destinationParentExpectation: WorkspaceItemMutationExpectation
    ) -> WorkspaceItemMutationOutcome<Void> {
        restoreIndeterminateRelocation(
            from: retainedSource,
            to: workspaceDestination,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            hooks: .production
        )
    }

    static func restoreIndeterminateRelocation(
        from retainedSource: WorkspaceFileSystemLocation,
        to workspaceDestination: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        destinationParentExpectation: WorkspaceItemMutationExpectation,
        hooks: WorkspaceItemMutationHooks
    ) -> WorkspaceItemMutationOutcome<Void> {
        let retainedParentExpectation = retainedSource.rootAuthority.directoryMutationExpectation
        guard !retainedSource.relativePath.utf8.contains(0x2F),
              retainedParentExpectation == sourceParentExpectation
        else {
            return .notMoved(.sourceChanged)
        }
        let relocation = WorkspaceItemRelocation(
            source: retainedSource,
            destination: workspaceDestination,
            expectation: expectation
        )
        if expectation.kind == .directory,
           retainedSource.rootAuthority == workspaceDestination.rootAuthority,
           workspaceDestination.relativePath.isByteExactDescendant(
               of: retainedSource.relativePath
           )
        {
            return .notMoved(.destinationInsideSource)
        }

        if retainedSource == workspaceDestination {
            return prepareUnchangedRelocation(
                relocation,
                sourceParentExpectation: sourceParentExpectation,
                destinationParentExpectation: destinationParentExpectation,
                preparingCommit: { _ in () }
            )
        }

        return performRelocation(
            relocation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            preparingCommit: { _ in () },
            hooks: hooks
        )
    }
}

private extension WorkspaceAnchoredItemMutator {
    struct RelocationContext {
        let relocation: WorkspaceItemRelocation
        let sourceChain: WorkspaceAnchoredFileSystem.DirectoryDescriptorChain
        let sourceParentDescriptor: Int32
        let sourceLeaf: String
        let destinationChain: WorkspaceAnchoredFileSystem.DirectoryDescriptorChain
        let destinationParentDescriptor: Int32
        let destinationLeaf: String
        let sourceParentExpectation: WorkspaceItemMutationExpectation
        let destinationParentExpectation: WorkspaceItemMutationExpectation
        let hooks: WorkspaceItemMutationHooks
    }

    static func prepareUnchangedRelocation<Prepared>(
        _ relocation: WorkspaceItemRelocation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        destinationParentExpectation: WorkspaceItemMutationExpectation,
        preparingCommit: (WorkspaceItemRelocation) throws -> Prepared
    ) -> WorkspaceItemMutationOutcome<Prepared> {
        do {
            guard try WorkspaceNoFollowItemInspector.inspect(at: relocation.source) == relocation.expectation else {
                return .notMoved(.sourceChanged)
            }
            try validateParentExpectation(
                at: relocation.source,
                expecting: sourceParentExpectation,
                failure: .sourceChanged
            )
            try validateParentExpectation(
                at: relocation.destination,
                expecting: destinationParentExpectation,
                failure: .destinationChanged
            )
        } catch {
            return .notMoved(failure(for: error, missingIsSource: true))
        }
        do {
            return try .movedAndDurable(
                relocation: relocation,
                preparedCommit: preparingCommit(relocation)
            )
        } catch {
            return .notMoved(.commitPreparationFailed)
        }
    }

    static func performRelocation<Prepared>(
        _ relocation: WorkspaceItemRelocation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        destinationParentExpectation: WorkspaceItemMutationExpectation,
        preparingCommit: (WorkspaceItemRelocation) throws -> Prepared,
        hooks: WorkspaceItemMutationHooks
    ) -> WorkspaceItemMutationOutcome<Prepared> {
        WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: relocation.source) {
            WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: relocation.destination) {
                do {
                    return try WorkspaceAnchoredFileSystem.withAnchoredParent(
                        at: relocation.source,
                        hooks: .production
                    ) { sourceChain, sourceParentDescriptor, sourceLeaf in
                        try WorkspaceAnchoredFileSystem.withAnchoredParent(
                            at: relocation.destination,
                            hooks: .production
                        ) { destinationChain, destinationParentDescriptor, destinationLeaf in
                            executeRelocation(
                                context: RelocationContext(
                                    relocation: relocation,
                                    sourceChain: sourceChain,
                                    sourceParentDescriptor: sourceParentDescriptor,
                                    sourceLeaf: sourceLeaf,
                                    destinationChain: destinationChain,
                                    destinationParentDescriptor: destinationParentDescriptor,
                                    destinationLeaf: destinationLeaf,
                                    sourceParentExpectation: sourceParentExpectation,
                                    destinationParentExpectation: destinationParentExpectation,
                                    hooks: hooks
                                ),
                                preparingCommit: preparingCommit
                            )
                        }
                    }
                } catch {
                    return .notMoved(Self.failure(for: error, missingIsSource: true))
                }
            }
        }
    }

    static func executeRelocation<Prepared>(
        context: RelocationContext,
        preparingCommit: (WorkspaceItemRelocation) throws -> Prepared
    ) -> WorkspaceItemMutationOutcome<Prepared> {
        let expectation = context.relocation.expectation
        do {
            let sourceEntry = try sourceEntry(
                parentDescriptor: context.sourceParentDescriptor,
                leaf: context.sourceLeaf
            )
            guard sourceEntry.mutationExpectation == expectation else {
                throw WorkspaceItemMutationFailure.sourceChanged
            }
            try requireAvailableDestination(context: context, sourceEntry: sourceEntry)
            try validatePreflight(context: context, sourceEntry: sourceEntry)
            try context.hooks.check(.willRename)
            let renameResult = renameExclusive(context)
            guard renameResult == 0 else {
                throw renameFailure(errno)
            }
        } catch {
            return .notMoved(Self.failure(for: error, missingIsSource: true))
        }

        let movedEntry: WorkspaceAnchoredFileSystem.DirectoryEntryIdentity
        do {
            movedEntry = try WorkspaceAnchoredFileSystem.directoryEntryIdentity(
                parentDescriptor: context.destinationParentDescriptor,
                component: context.destinationLeaf
            )
            context.hooks.emit(.didRename)
        } catch {
            return .movedButIndeterminate(.init(
                relocation: context.relocation,
                reason: Self.failure(for: error),
                preparedCommit: nil,
                actualMovedExpectation: nil
            ))
        }

        do {
            try validatePostflight(
                context: context,
                expectation: expectation,
                movedEntry: movedEntry
            )
        } catch {
            return rollbackOrIndeterminate(
                reason: Self.failure(for: error),
                movedEntry: movedEntry,
                context: context
            )
        }

        let preparedCommit: Prepared
        do {
            try context.hooks.check(.willPrepareCommit)
            preparedCommit = try preparingCommit(context.relocation)
        } catch {
            return rollbackOrIndeterminate(
                reason: .commitPreparationFailed,
                movedEntry: movedEntry,
                context: context
            )
        }

        do {
            try syncMutationParents(context)
            try validatePostflight(
                context: context,
                expectation: expectation,
                movedEntry: movedEntry
            )
        } catch {
            return rollbackOrIndeterminate(
                reason: Self.failure(for: error),
                preparedCommit: preparedCommit,
                movedEntry: movedEntry,
                context: context
            )
        }
        return .movedAndDurable(
            relocation: context.relocation,
            preparedCommit: preparedCommit
        )
    }

    static func sourceEntry(
        parentDescriptor: Int32,
        leaf: String
    ) throws -> WorkspaceAnchoredFileSystem.DirectoryEntryIdentity {
        do {
            guard let entry = try WorkspaceAnchoredFileSystem.exactDirectoryEntry(
                parentDescriptor: parentDescriptor,
                leaf: leaf
            ) else {
                throw WorkspaceItemMutationFailure.sourceMissing
            }
            return entry
        } catch WorkspaceAnchoredFileSystemError.missing {
            throw WorkspaceItemMutationFailure.sourceMissing
        }
    }

    static func requireAvailableDestination(
        context: RelocationContext,
        sourceEntry: WorkspaceAnchoredFileSystem.DirectoryEntryIdentity
    ) throws {
        if try WorkspaceAnchoredFileSystem.exactDirectoryEntry(
            parentDescriptor: context.destinationParentDescriptor,
            leaf: context.destinationLeaf
        ) != nil {
            throw WorkspaceItemMutationFailure.destinationExists
        }

        let resolvedDestination: WorkspaceAnchoredFileSystem.DirectoryEntryIdentity
        do {
            resolvedDestination = try WorkspaceAnchoredFileSystem.directoryEntryIdentity(
                parentDescriptor: context.destinationParentDescriptor,
                component: context.destinationLeaf
            )
        } catch WorkspaceAnchoredFileSystemError.missing {
            return
        }

        let sourceParentIdentity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(
            context.sourceParentDescriptor
        )
        let destinationParentIdentity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(
            context.destinationParentDescriptor
        )
        guard sourceParentIdentity == destinationParentIdentity,
              resolvedDestination == sourceEntry,
              !context.sourceLeaf.utf8.elementsEqual(context.destinationLeaf.utf8)
        else {
            throw WorkspaceItemMutationFailure.destinationExists
        }
    }

    static func validatePreflight(
        context: RelocationContext,
        sourceEntry: WorkspaceAnchoredFileSystem.DirectoryEntryIdentity
    ) throws {
        try context.sourceChain.validateNamespace()
        try context.destinationChain.validateNamespace()
        try validateParentDescriptor(
            context.sourceParentDescriptor,
            expecting: context.sourceParentExpectation,
            failure: .sourceChanged
        )
        try validateParentDescriptor(
            context.destinationParentDescriptor,
            expecting: context.destinationParentExpectation,
            failure: .destinationChanged
        )
        try WorkspaceAnchoredFileSystem.validateNameStillReferencesEntry(
            parentDescriptor: context.sourceParentDescriptor,
            leaf: context.sourceLeaf,
            entry: sourceEntry
        )
        try requireAvailableDestination(context: context, sourceEntry: sourceEntry)
        try context.sourceChain.validateNamespace()
        try context.destinationChain.validateNamespace()
    }

    static func validatePostflight(
        context: RelocationContext,
        expectation: WorkspaceItemMutationExpectation,
        movedEntry: WorkspaceAnchoredFileSystem.DirectoryEntryIdentity
    ) throws {
        guard let destinationEntry = try WorkspaceAnchoredFileSystem.exactDirectoryEntry(
            parentDescriptor: context.destinationParentDescriptor,
            leaf: context.destinationLeaf
        ) else {
            throw WorkspaceItemMutationFailure.namespaceChanged
        }
        guard destinationEntry == movedEntry else {
            throw WorkspaceItemMutationFailure.namespaceChanged
        }
        guard destinationEntry.mutationExpectation == expectation else {
            throw WorkspaceItemMutationFailure.sourceChanged
        }
        if try WorkspaceAnchoredFileSystem.exactDirectoryEntry(
            parentDescriptor: context.sourceParentDescriptor,
            leaf: context.sourceLeaf
        ) != nil {
            throw WorkspaceItemMutationFailure.namespaceChanged
        }
        try context.destinationChain.validateNamespace()
        try context.sourceChain.validateNamespace()
        try validateParentDescriptor(
            context.sourceParentDescriptor,
            expecting: context.sourceParentExpectation,
            failure: .sourceChanged
        )
        try validateParentDescriptor(
            context.destinationParentDescriptor,
            expecting: context.destinationParentExpectation,
            failure: .destinationChanged
        )
        try WorkspaceAnchoredFileSystem.validateNameStillReferencesEntry(
            parentDescriptor: context.destinationParentDescriptor,
            leaf: context.destinationLeaf,
            entry: destinationEntry
        )
        try context.destinationChain.validateNamespace()
        try context.sourceChain.validateNamespace()
    }

    static func rollbackOrIndeterminate<Prepared>(
        reason: WorkspaceItemMutationFailure,
        preparedCommit: Prepared? = nil,
        movedEntry: WorkspaceAnchoredFileSystem.DirectoryEntryIdentity,
        context: RelocationContext
    ) -> WorkspaceItemMutationOutcome<Prepared> {
        .movedButIndeterminate(.init(
            relocation: context.relocation,
            reason: reason,
            preparedCommit: preparedCommit,
            actualMovedExpectation: movedEntry.mutationExpectation
        ))
    }

    static func renameExclusive(_ context: RelocationContext) -> Int32 {
        context.relocation.destination.rootAuthority.withRetainedRootDescriptor {
            destinationRootDescriptor in
            context.sourceLeaf.withCString { sourceLeaf in
                context.relocation.destination.relativePath.withCString { destinationPath in
                    // The source name is resolved from the exact parent descriptor validated by
                    // preflight, so replacing that parent at its workspace path cannot redirect
                    // the syscall to a foreign same-named entry. The complete destination stays
                    // rooted at its retained authority, so moving the opened destination parent
                    // outside the workspace cannot redirect publication outside the root.
                    Darwin.renameatx_np(
                        context.sourceParentDescriptor,
                        sourceLeaf,
                        destinationRootDescriptor,
                        destinationPath,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
        }
    }

    static func syncMutationParents(_ context: RelocationContext) throws {
        try context.hooks.check(.willSyncDestinationParent)
        try WorkspaceAnchoredFileSystem.syncDirectory(context.destinationParentDescriptor)
        let sourceIdentity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(
            context.sourceParentDescriptor
        )
        let destinationIdentity = try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(
            context.destinationParentDescriptor
        )
        guard sourceIdentity != destinationIdentity else { return }
        try context.hooks.check(.willSyncSourceParent)
        try WorkspaceAnchoredFileSystem.syncDirectory(context.sourceParentDescriptor)
    }

    static func renameFailure(_ errorNumber: Int32) -> WorkspaceItemMutationFailure {
        switch errorNumber {
        case EEXIST, ENOTEMPTY:
            .destinationExists
        case ENOENT, ENOTDIR:
            .sourceChanged
        case EXDEV:
            .crossDevice
        default:
            .unreadable
        }
    }

    static func validateParentExpectation(
        at child: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation,
        failure: WorkspaceItemMutationFailure
    ) throws {
        try WorkspaceAnchoredFileSystem.withSecurityScopedAccess(to: child) {
            try WorkspaceAnchoredFileSystem.withAnchoredParent(
                at: child,
                hooks: .production
            ) { chain, parentDescriptor, _ in
                try validateParentDescriptor(
                    parentDescriptor,
                    expecting: expectation,
                    failure: failure
                )
                try chain.validateNamespace()
            }
        }
    }

    static func validateParentDescriptor(
        _ descriptor: Int32,
        expecting expectation: WorkspaceItemMutationExpectation,
        failure: WorkspaceItemMutationFailure
    ) throws {
        guard expectation.kind == .directory,
              try WorkspaceAnchoredFileSystem.directoryDescriptorIdentity(descriptor)
              == expectation.identity
        else {
            throw failure
        }
    }

    static func failure(
        for error: Error,
        missingIsSource: Bool = false
    ) -> WorkspaceItemMutationFailure {
        if let failure = error as? WorkspaceItemMutationFailure {
            return failure
        }
        guard let anchoredError = error as? WorkspaceAnchoredFileSystemError else {
            return .unreadable
        }
        return switch anchoredError {
        case .missing:
            missingIsSource ? .sourceMissing : .namespaceChanged
        case .changedIdentity:
            .sourceChanged
        case .namespaceChanged, .symbolicLink, .notRegularFile, .unstable:
            .namespaceChanged
        case .durabilityFailed:
            .durabilityFailed
        case .cancelled:
            .cancelled
        case .unreadable, .changedContent, .cleanupFailed:
            .unreadable
        }
    }
}

extension WorkspaceAnchoredFileSystem.DirectoryEntryIdentity {
    var mutationExpectation: WorkspaceItemMutationExpectation {
        WorkspaceItemMutationExpectation(
            identity: identity,
            kind: WorkspaceFileSystemItemKind(mode: fileType)
        )
    }
}

private extension String {
    func isByteExactDescendant(of ancestor: String) -> Bool {
        let ancestorComponents = ancestor.split(separator: "/", omittingEmptySubsequences: true)
        let components = split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > ancestorComponents.count else { return false }
        return zip(components, ancestorComponents).allSatisfy { component, ancestorComponent in
            component.utf8.elementsEqual(ancestorComponent.utf8)
        }
    }
}
