import Foundation

public enum EditorImageAsset: Equatable, Sendable {
    case data(Data, suggestedFilename: String)
    case file(URL)
}

/// Transactional result of placing editor image assets.
///
/// The caller commits the transaction only after the Markdown reference is accepted
/// by the exact document writer. Every other path calls `discard`, allowing the App
/// to remove only files created by this insertion attempt.
public struct EditorImageAssetInsertion: Sendable {
    public let relativePaths: [String]
    private let discardHandler: @MainActor @Sendable () async -> Void

    public init(
        relativePaths: [String],
        discard: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.relativePaths = relativePaths
        discardHandler = discard
    }

    @MainActor
    func discard() async {
        await discardHandler()
    }
}

public typealias EditorImageAssetInserter = @MainActor @Sendable (
    [EditorImageAsset]
) async -> EditorImageAssetInsertion
