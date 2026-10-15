import Foundation
import MarkdownCore

public struct AuthoringAuthority: Equatable, Sendable {
    public var bindingID: UUID
    public var documentID: IOSDocumentIdentity
    public var version: Int
    public var selectionGeneration: UInt64
    public var source: String
    public var selection: NSRange

    public init(
        bindingID: UUID,
        documentID: IOSDocumentIdentity,
        version: Int,
        selectionGeneration: UInt64,
        source: String,
        selection: NSRange
    ) {
        self.bindingID = bindingID
        self.documentID = documentID
        self.version = version
        self.selectionGeneration = selectionGeneration
        self.source = source
        self.selection = selection
    }

    public func matches(_ other: AuthoringAuthority) -> Bool {
        bindingID == other.bindingID
            && documentID == other.documentID
            && version == other.version
            && selectionGeneration == other.selectionGeneration
            && selection == other.selection
            && ExactSourceText.matches(source, other.source)
    }
}

public struct EditorProbe: Equatable, Sendable {
    public var source: String
    public var selection: NSRange
    /// Probe counter only. This is not an `UndoManager` registration and is not
    /// native Undo evidence.
    public var undoRegistrations: Int

    public init(source: String, selection: NSRange, undoRegistrations: Int = 0) {
        self.source = source
        self.selection = selection
        self.undoRegistrations = undoRegistrations
    }
}

public enum AuthoringAcceptance {
    /// Plans one literal replace of the session's current match.
    ///
    /// The caret is the live selection's UTF-16 location. The match is accepted
    /// only when that selection is exactly `currentMatch.range`. Any other hit,
    /// a moved selection, or a stale range leaves the probe untouched.
    /// `undoRegistrations` increments on the probe only.
    @discardableResult
    public static func singleReplace(
        probe: inout EditorProbe,
        captured: AuthoringAuthority,
        live: AuthoringAuthority,
        pattern: String,
        replacement: String
    ) -> Bool {
        guard captured.matches(live),
              ExactSourceText.matches(live.source, probe.source),
              live.selection == probe.selection
        else {
            return false
        }
        let caret = max(0, live.selection.location)
        let session = EditorFindSession.search(
            in: live.source,
            query: TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive),
            caretAnchorUTF16: caret
        )
        guard let ordinal = session.currentOrdinal,
              let accepted = session.currentMatch,
              accepted.range == live.selection
        else {
            return false
        }
        let authorized = session.withCurrentOrdinal(ordinal, caretAnchorUTF16: caret)
        guard case let .success(plan) = EditorReplacePlanner.planOneMatch(
            session: authorized,
            source: live.source,
            replacement: replacement
        ), !plan.isLiteralIdentical, plan.match.range == accepted.range else {
            return false
        }
        guard let updated = EditorReplaceSourceConstruction.replacedSource(
            live.source,
            ranges: [plan.match.range],
            replacement: replacement
        ), !ExactSourceText.matches(updated, probe.source) else {
            return false
        }
        probe.source = updated
        probe.selection = NSRange(location: plan.resumeUTF16, length: 0)
        probe.undoRegistrations += 1
        return true
    }
}
