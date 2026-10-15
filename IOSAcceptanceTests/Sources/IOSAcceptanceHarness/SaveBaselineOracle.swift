import Foundation
import MarkdownCore

public struct SaveAcknowledgementEffect: Equatable, Sendable {
    public let text: String
    public let version: Int
    public let isDirty: Bool
    public let applied: Bool
}

/// Applies only `rebaseSavedText(to:)`, and only for a newer operation order.
/// An older completion cannot mark a newer draft clean or replace its text.
@MainActor
public final class SaveBaselineOracle {
    private var appliedOrder = 0

    public init() {}

    public func acknowledge(
        session: DocumentSession,
        order: Int,
        capturedVersion: Int,
        persistedText: String
    ) -> SaveAcknowledgementEffect {
        let before = SaveAcknowledgementEffect(
            text: session.text,
            version: session.version,
            isDirty: session.isDirty,
            applied: false
        )
        guard order > appliedOrder, capturedVersion <= session.version else {
            return before
        }
        session.rebaseSavedText(to: persistedText)
        appliedOrder = order
        return SaveAcknowledgementEffect(
            text: session.text,
            version: session.version,
            isDirty: session.isDirty,
            applied: true
        )
    }
}
