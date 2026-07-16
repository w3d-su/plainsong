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
    private let discardHandler: @MainActor @Sendable () async -> Void

    public init(
        relativePaths: [String],
        validateBeforeCommit: @escaping @MainActor @Sendable () async -> Bool = { true },
        discard: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.relativePaths = relativePaths
        validateBeforeCommitHandler = validateBeforeCommit
        discardHandler = discard
    }

    @MainActor
    func validateBeforeCommit() async -> Bool {
        await validateBeforeCommitHandler()
    }

    @MainActor
    func discard() async {
        await discardHandler()
    }
}

public typealias EditorImageAssetInserter = @MainActor @Sendable (
    [EditorImageAsset]
) async -> EditorImageAssetInsertion
