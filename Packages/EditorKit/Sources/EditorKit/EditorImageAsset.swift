import Foundation

public enum EditorImageAsset: Equatable, Sendable {
    case data(Data, suggestedFilename: String)
    case file(URL)
}

/// Transactional result of placing editor image assets.
///
/// The caller commits the transaction only after the Markdown reference is accepted
/// by the exact document writer. Every other path calls `discard`, allowing the App
/// to remove the created assets from their publish names and surface any retained
/// recovery data without touching an unproven namespace occupant.
public struct EditorImageAssetInsertion: Sendable {
    public let relativePaths: [String]
    private let validateBeforeCommitHandler: @MainActor @Sendable () async -> Bool
    private let terminal: EditorImageAssetInsertionTerminal

    public init(
        relativePaths: [String],
        validateBeforeCommit: @escaping @MainActor @Sendable () async -> Bool = { true },
        commit: @escaping @MainActor @Sendable () -> Void = {},
        discard: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.relativePaths = relativePaths
        validateBeforeCommitHandler = validateBeforeCommit
        terminal = EditorImageAssetInsertionTerminal(
            commit: commit,
            discard: discard
        )
    }

    @MainActor
    func validateBeforeCommit() async -> Bool {
        await validateBeforeCommitHandler()
    }

    @MainActor
    func commit() {
        terminal.commit()
    }

    @MainActor
    func discard() async {
        await terminal.discard()
    }
}

private final class EditorImageAssetInsertionTerminal: @unchecked Sendable {
    private enum State {
        case active
        case committed
        case discarded
    }

    private var state = State.active
    private let commitHandler: @MainActor @Sendable () -> Void
    private let discardHandler: @MainActor @Sendable () async -> Void

    init(
        commit: @escaping @MainActor @Sendable () -> Void,
        discard: @escaping @MainActor @Sendable () async -> Void
    ) {
        commitHandler = commit
        discardHandler = discard
    }

    @MainActor
    func commit() {
        guard state == .active else {
            return
        }
        state = .committed
        commitHandler()
    }

    @MainActor
    func discard() async {
        guard state == .active else {
            return
        }
        state = .discarded
        await discardHandler()
    }
}

public typealias EditorImageAssetInserter = @MainActor @Sendable (
    [EditorImageAsset]
) async -> EditorImageAssetInsertion
