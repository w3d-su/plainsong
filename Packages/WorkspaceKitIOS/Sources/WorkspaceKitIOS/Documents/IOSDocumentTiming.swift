import Foundation

/// Autosave uses the existing one-second delay. Background flush is bounded and does not
/// claim a provider write finished after the budget.
public struct IOSDocumentTiming: Sendable, Equatable {
    public var autosaveDelayNanoseconds: UInt64
    public var backgroundFlushNanoseconds: UInt64

    public init(autosaveDelayNanoseconds: UInt64, backgroundFlushNanoseconds: UInt64) {
        self.autosaveDelayNanoseconds = autosaveDelayNanoseconds
        self.backgroundFlushNanoseconds = backgroundFlushNanoseconds
    }

    public static let production = IOSDocumentTiming(
        autosaveDelayNanoseconds: 1_000_000_000,
        backgroundFlushNanoseconds: 5_000_000_000
    )
}
