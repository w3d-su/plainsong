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
    public var undoRegistrations: Int

    public init(source: String, selection: NSRange, undoRegistrations: Int = 0) {
        self.source = source
        self.selection = selection
        self.undoRegistrations = undoRegistrations
    }
}

public enum AuthoringAcceptance {
    /// Plans one literal replace against the captured authority. Refusal leaves the
    /// probe's source, selection, and undo registration count untouched.
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
        let session = EditorFindSession.search(
            in: live.source,
            query: TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive)
        )
        guard case let .success(plan) = EditorReplacePlanner.planOneMatch(
            session: session,
            source: live.source,
            replacement: replacement
        ), !plan.isLiteralIdentical else {
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
