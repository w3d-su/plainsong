import Foundation

public enum EditorImageAsset: Equatable, Sendable {
    case data(Data, suggestedFilename: String)
    case file(URL)
}

public typealias EditorImageAssetInserter = @MainActor @Sendable ([EditorImageAsset]) async -> [String]
