import Darwin
import Foundation

final class WorkspaceDirectoryCloneSource {
    let descriptor: Int32
    let policy: WorkspaceDirectoryClonePolicy
    let reportedPath: Data

    init(
        descriptor: Int32,
        policy: WorkspaceDirectoryClonePolicy,
        reportedPath: Data
    ) {
        self.descriptor = descriptor
        self.policy = policy
        self.reportedPath = reportedPath
    }

    deinit {
        Darwin.close(descriptor)
    }
}

final class WorkspaceDirectoryCloneSourceRegistry: @unchecked Sendable {
    static let shared = WorkspaceDirectoryCloneSourceRegistry()

    private let lock = NSLock()
    private var sourcesByDevice: [UInt64: WorkspaceDirectoryCloneSource] = [:]

    func withSource<T>(
        for device: UInt64,
        create: () throws -> WorkspaceDirectoryCloneSource,
        validate: (WorkspaceDirectoryCloneSource) throws -> Void,
        _ body: (WorkspaceDirectoryCloneSource) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        var source = sourcesByDevice[device]
        if let current = source {
            do {
                try validate(current)
            } catch {
                sourcesByDevice[device] = nil
                source = nil
            }
        }
        if source == nil {
            let created = try create()
            try validate(created)
            sourcesByDevice[device] = created
            source = created
        }
        guard let source else {
            throw WorkspaceItemMutationFailure.unreadable
        }
        return try body(source)
    }

    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        sourcesByDevice.removeAll()
    }
}

enum WorkspaceDirectoryExtendedAttributeValue: Equatable {
    case readable(Data)
    case accessControlled
}

struct WorkspaceDirectoryClonePolicy: Equatable {
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let extendedAttributes: [String: WorkspaceDirectoryExtendedAttributeValue]
}

struct WorkspaceDirectoryCloneResult {
    let sourceRemainedExact: Bool
}

public enum WorkspaceItemCreationRecoveryState: Sendable, Equatable {
    case none
    case retained(WorkspaceFileSystemLocation)
    case removalIndeterminate(WorkspaceFileSystemLocation)
    case unknown

    public var location: WorkspaceFileSystemLocation? {
        switch self {
        case .none, .unknown:
            nil
        case let .retained(location), let .removalIndeterminate(location):
            location
        }
    }
}

public struct WorkspaceCreatedItem: Sendable, Equatable {
    public let location: WorkspaceFileSystemLocation
    public let expectation: WorkspaceItemMutationExpectation

    public init(
        location: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation
    ) {
        self.location = location
        self.expectation = expectation
    }
}

public struct WorkspaceIndeterminateItemCreation: Sendable, Equatable {
    public let destination: WorkspaceFileSystemLocation
    public let reason: WorkspaceItemMutationFailure
    public let recoveryState: WorkspaceItemCreationRecoveryState
    public let createdExpectation: WorkspaceItemMutationExpectation?
    public let recoveryExpectation: WorkspaceItemMutationExpectation?
    public let publicationSource: WorkspaceFileSystemLocation?
    public let actualPublishedExpectation: WorkspaceItemMutationExpectation?

    public init(
        destination: WorkspaceFileSystemLocation,
        reason: WorkspaceItemMutationFailure,
        recoveryState: WorkspaceItemCreationRecoveryState,
        createdExpectation: WorkspaceItemMutationExpectation? = nil,
        recoveryExpectation: WorkspaceItemMutationExpectation? = nil,
        publicationSource: WorkspaceFileSystemLocation? = nil,
        actualPublishedExpectation: WorkspaceItemMutationExpectation? = nil
    ) {
        self.destination = destination
        self.reason = reason
        self.recoveryState = recoveryState
        self.createdExpectation = createdExpectation
        self.recoveryExpectation = recoveryExpectation
        self.publicationSource = publicationSource
        self.actualPublishedExpectation = actualPublishedExpectation
    }
}

public enum WorkspaceItemCreationOutcome: Sendable, Equatable {
    case notCreated(WorkspaceItemMutationFailure)
    case createdAndDurable(WorkspaceCreatedItem)
    case creationStateIndeterminate(WorkspaceIndeterminateItemCreation)
}

public enum WorkspaceItemCreationPlanKind: Sendable, Equatable {
    case file
    case folder
}

public struct WorkspaceItemCreationPlan: Sendable, Equatable {
    public let kind: WorkspaceItemCreationPlanKind
    public let destination: WorkspaceFileSystemLocation
    public let parentExpectation: WorkspaceItemMutationExpectation
    /// A unique, root-level publication source reserved before any artifact exists. Plans made
    /// by `WorkspaceFileOperations` always provide this value; optionality only keeps manually
    /// constructed invalid plans representable so execution can reject them without trapping.
    public let stagingLocation: WorkspaceFileSystemLocation?
}

/// The exact durable staging identity recorded by the caller before destination publication.
/// `location` is the plan's root-level staging location, never the mutable destination path.
public struct WorkspacePreparedItemCreationArtifact: Sendable, Equatable {
    public let location: WorkspaceFileSystemLocation
    public let expectation: WorkspaceItemMutationExpectation

    public init(
        location: WorkspaceFileSystemLocation,
        expectation: WorkspaceItemMutationExpectation
    ) {
        self.location = location
        self.expectation = expectation
    }
}

enum WorkspaceItemCreationEvent: Equatable {
    case willCreate
    case willUnlinkDirectorySource(Int32, URL)
    case willRemoveVerifiedDirectorySource(Int32, URL)
    case willCloneDirectorySource(Int32)
    case didCreateName
    case didCreate
    case willSyncParent
    case postflight
}

enum WorkspaceItemCreationInjectedCall: Hashable {
    case createDirectory
    case syncCreatedDirectory
    case syncParent
}

struct WorkspaceItemCreationHooks {
    static let production = WorkspaceItemCreationHooks()

    let eventHandler: (@Sendable (WorkspaceItemCreationEvent) -> Void)?
    let injectedFailure: (@Sendable (WorkspaceItemCreationInjectedCall) -> WorkspaceItemMutationFailure?)?

    init(
        eventHandler: (@Sendable (WorkspaceItemCreationEvent) -> Void)? = nil,
        injectedFailure: (@Sendable (WorkspaceItemCreationInjectedCall) -> WorkspaceItemMutationFailure?)? = nil
    ) {
        self.eventHandler = eventHandler
        self.injectedFailure = injectedFailure
    }

    func emit(_ event: WorkspaceItemCreationEvent) {
        eventHandler?(event)
    }

    func check(_ call: WorkspaceItemCreationInjectedCall) throws {
        if let failure = injectedFailure?(call) {
            throw failure
        }
    }
}
