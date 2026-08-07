import AppKit
import Foundation

/// Find-match highlight requested by the App for the focused editor (docs/editor-find-gates.md F8).
///
/// Ranges are raw UTF-16 offsets into the backing source, exactly like
/// `EditorNavigationRequest.selection`. Highlighting is presentation only: it never mutates
/// source text, never registers undo, and never moves the selection.
public struct EditorFindMatchHighlightRequest: Equatable, Sendable {
    /// Monotonic identity of the producing find session. A newer generation replaces older
    /// decoration wholesale rather than merging into it.
    public let generation: UInt64
    /// Match ranges to decorate, in ascending UTF-16 order.
    public let matches: [NSRange]
    /// Index into `matches` for the current match, or `nil` when there is no current match.
    public let currentIndex: Int?

    public init(generation: UInt64, matches: [NSRange], currentIndex: Int?) {
        self.generation = generation
        self.matches = matches
        self.currentIndex = currentIndex
    }

    public static let none = EditorFindMatchHighlightRequest(
        generation: 0,
        matches: [],
        currentIndex: nil
    )
}

/// Marker carried by backing ranges that currently show a find-match highlight.
///
/// This exists for the same reason `WYSIWYGImagePresentationMarker` does: highlight
/// application uses `setAttributes`, which replaces every attribute in the range. Without a
/// marker to collect and restore, find decoration would be wiped on the next visible-range
/// recompute — the failure this gate (F8) exists to prevent.
final class EditorFindMatchHighlightMarker: NSObject {
    static let attribute = NSAttributedString.Key("app.plainsong.editorFind.matchHighlight")

    // Keep NSObject's identity equality. Adjacent matches can have the same role/generation but
    // distinct covered backgrounds; semantic equality lets NSTextStorage merge those runs and
    // discard one marker's restoration metadata.

    enum Role: Equatable {
        /// The match the user is currently on.
        case current
        /// Any other match of the same query.
        case other
    }

    /// A `.backgroundColor` run this decoration painted over, so clearing can put it back.
    struct CoveredBackground {
        let range: NSRange
        let color: NSColor
    }

    let role: Role
    let generation: UInt64
    /// Syntax backgrounds (inline code, fenced blocks, frontmatter) hidden under this match.
    /// Ranges are relative to the marker so they stay valid when NSTextStorage moves the marker
    /// through a character edit. A single match can span several, so this is a list, not one colour.
    let coveredBackgrounds: [CoveredBackground]

    init(role: Role, generation: UInt64, coveredBackgrounds: [CoveredBackground]) {
        self.role = role
        self.generation = generation
        self.coveredBackgrounds = coveredBackgrounds
    }
}

/// Applies, clears, and preserves find-match decoration on a text storage.
@MainActor
enum EditorFindMatchHighlight {
    /// Background colour for a role. System colours so both appearances follow the OS.
    static func backgroundColor(for role: EditorFindMatchHighlightMarker.Role) -> NSColor {
        switch role {
        case .current: .findHighlightColor
        case .other: .unemphasizedSelectedTextBackgroundColor
        }
    }

    /// How far beyond the visible range decoration is materialised, so small scrolls do not
    /// immediately expose undecorated matches.
    static let visibleRangePadding = 2000

    /// Replaces find decoration with `request`, materialising only what is near the viewport.
    ///
    /// Two costs are bounded here. Decoration covers matches intersecting `visibleRange` padded
    /// by `visibleRangePadding` rather than all `retainedMatchCeiling` (10_000) of them, and the
    /// removal pass searches `previouslyDecorated` rather than walking the whole storage — a
    /// full-document enumeration walks every syntax run, so its cost comes from the document
    /// size, not from how few runs carry find decoration.
    ///
    /// Returns the span that now holds decoration, to be passed back as `previouslyDecorated`.
    ///
    /// A match that no longer fits the current text is dropped rather than clamped: clamping
    /// would light up characters that are not matches.
    @discardableResult
    static func apply(
        _ request: EditorFindMatchHighlightRequest?,
        visibleRange: NSRange?,
        previouslyDecorated: NSRange?,
        to textStorage: NSTextStorage
    ) -> NSRange? {
        textStorage.beginEditing()
        defer { textStorage.endEditing() }
        let length = textStorage.length
        let materialisationRange = materialisationRange(for: visibleRange, storageLength: length)
        // Search where decoration was and where it is about to go as separate windows. Taking
        // their union would scan the entire gap after a large edit moved the old marker far from
        // the viewport, defeating the viewport bound precisely when cleanup matters most.
        let clearRanges = [previouslyDecorated, materialisationRange]
            .compactMap { $0 }
        clear(in: textStorage, searching: clearRanges)

        guard let request, !request.matches.isEmpty else { return nil }
        var decorated: NSRange?

        for (index, match) in request.matches.enumerated() {
            // Subtraction, not `location + length <= storageLength`: this is a public request,
            // and a range near `Int.max` would trap on the addition instead of being dropped.
            guard match.length > 0,
                  match.location >= 0,
                  match.location <= length,
                  length - match.location >= match.length,
                  NSIntersectionRange(match, materialisationRange).length > 0
            else {
                continue
            }
            let role: EditorFindMatchHighlightMarker.Role =
                index == request.currentIndex ? .current : .other
            decorate(range: match, role: role, generation: request.generation, in: textStorage)
            decorated = decorated.map { NSUnionRange($0, match) } ?? match
        }
        return decorated
    }

    /// The span decoration is materialised in: the padded visible range, or the whole storage
    /// when the viewport is unknown (no reporter attached yet).
    static func materialisationRange(
        for visibleRange: NSRange?,
        storageLength: Int
    ) -> NSRange {
        let safeStorageLength = max(0, storageLength)
        let whole = NSRange(location: 0, length: safeStorageLength)
        guard let visibleRange, visibleRange.location != NSNotFound else { return whole }
        guard visibleRange.location >= 0,
              visibleRange.location <= safeStorageLength,
              visibleRange.length >= 0
        else {
            return NSRange(location: 0, length: 0)
        }
        let visibleStart = visibleRange.location
        let visibleLength = min(visibleRange.length, safeStorageLength - visibleStart)
        let start = visibleStart - min(visibleStart, visibleRangePadding)
        let visibleEnd = visibleStart + visibleLength
        let end = visibleEnd + min(safeStorageLength - visibleEnd, visibleRangePadding)
        guard end > start else { return NSRange(location: 0, length: 0) }
        return NSRange(location: start, length: end - start)
    }

    /// Overflow-safe containment for viewport/materialisation bookkeeping.
    static func range(_ outer: NSRange, contains inner: NSRange) -> Bool {
        guard outer.location >= 0,
              outer.length >= 0,
              inner.location >= outer.location,
              inner.length >= 0
        else {
            return false
        }
        let offset = inner.location - outer.location
        return offset <= outer.length && inner.length <= outer.length - offset
    }

    /// Moves a tracked presentation span through an authoritative `NSTextStorage` character edit.
    /// `editedRange` is in post-edit coordinates; `changeInLength` reconstructs the replaced range.
    static func range(
        _ tracked: NSRange,
        afterEditing editedRange: NSRange,
        changeInLength: Int,
        storageLength: Int
    ) -> NSRange? {
        guard tracked.location >= 0,
              tracked.length >= 0,
              editedRange.location >= 0,
              editedRange.length >= 0
        else {
            return nil
        }
        let (trackedEnd, trackedEndOverflow) = tracked.location.addingReportingOverflow(tracked.length)
        let (postEditEnd, postEditEndOverflow) = editedRange.location.addingReportingOverflow(editedRange.length)
        let (replacedLength, replacedLengthOverflow) = editedRange.length
            .subtractingReportingOverflow(changeInLength)
        guard !trackedEndOverflow,
              !postEditEndOverflow,
              !replacedLengthOverflow,
              replacedLength >= 0
        else {
            return nil
        }
        let (replacedEnd, replacedEndOverflow) = editedRange.location
            .addingReportingOverflow(replacedLength)
        guard !replacedEndOverflow else { return nil }

        let transformed: NSRange
        if replacedEnd < tracked.location
            || (replacedEnd == tracked.location && replacedLength > 0)
        {
            let (shiftedLocation, locationOverflow) = tracked.location
                .addingReportingOverflow(changeInLength)
            guard !locationOverflow else { return nil }
            transformed = NSRange(location: shiftedLocation, length: tracked.length)
        } else if editedRange.location > trackedEnd
            || (editedRange.location == trackedEnd && replacedLength > 0)
        {
            transformed = tracked
        } else {
            // The edit intersects or is an insertion at a marker boundary. Include both the
            // surviving old span and replacement because attributed-string insertion can inherit
            // neighbouring attributes at either boundary.
            let lower = min(tracked.location, editedRange.location)
            let (shiftedTrackedEnd, shiftedEndOverflow) = trackedEnd
                .addingReportingOverflow(changeInLength)
            guard !shiftedEndOverflow else { return nil }
            let upper = max(postEditEnd, shiftedTrackedEnd)
            guard upper >= lower else { return nil }
            transformed = NSRange(location: lower, length: upper - lower)
        }

        let clamped = transformed.clamped(toLength: max(0, storageLength))
        return clamped.length > 0 ? clamped : nil
    }

    /// Removes find decoration and puts back whatever background it covered.
    ///
    /// `searchRange` bounds the enumeration; `nil` searches the whole storage, which is correct
    /// but walks every syntax run in the document. Callers that know where they decorated should
    /// say so.
    ///
    /// Restoring the covered background matters because syntax highlighting owns
    /// `.backgroundColor` for inline code, fenced blocks, and frontmatter. Removing it outright
    /// stripped that styling from any match that overlapped one, and nothing recomputes it when
    /// the find bar closes.
    static func clear(in textStorage: NSTextStorage, searching searchRange: NSRange? = nil) {
        clear(
            in: textStorage,
            searching: [searchRange ?? NSRange(location: 0, length: textStorage.length)]
        )
    }

    /// Clears several independent windows without enumerating the gaps between them.
    @discardableResult
    static func clear(in textStorage: NSTextStorage, searching searchRanges: [NSRange]) -> Int {
        let clampedBounds = searchRanges
            .map { $0.clamped(toLength: textStorage.length) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        var bounds: [NSRange] = []
        for candidate in clampedBounds {
            if let last = bounds.last,
               last.location + last.length >= candidate.location
            {
                bounds[bounds.count - 1] = NSUnionRange(last, candidate)
            } else {
                bounds.append(candidate)
            }
        }
        guard !bounds.isEmpty else { return 0 }
        var decorated: [(range: NSRange, marker: EditorFindMatchHighlightMarker)] = []
        for bound in bounds {
            textStorage.enumerateAttribute(
                EditorFindMatchHighlightMarker.attribute,
                in: bound
            ) { value, range, _ in
                guard let marker = value as? EditorFindMatchHighlightMarker else { return }
                decorated.append((range, marker))
            }
        }
        for entry in decorated {
            textStorage.removeAttribute(
                EditorFindMatchHighlightMarker.attribute,
                range: entry.range
            )
            textStorage.removeAttribute(.backgroundColor, range: entry.range)
            for covered in entry.marker.coveredBackgrounds {
                let (location, overflow) = entry.range.location
                    .addingReportingOverflow(covered.range.location)
                guard !overflow else { continue }
                let clamped = NSRange(location: location, length: covered.range.length)
                    .clamped(toLength: textStorage.length)
                guard clamped.length > 0 else { continue }
                textStorage.addAttribute(.backgroundColor, value: covered.color, range: clamped)
            }
        }
        return bounds.reduce(0) { $0 + $1.length }
    }

    /// Collects markers so they can survive a `setAttributes` pass (F8).
    static func collect(
        in textStorage: NSTextStorage,
        range: NSRange
    ) -> [(range: NSRange, marker: EditorFindMatchHighlightMarker)] {
        var preserved: [(range: NSRange, marker: EditorFindMatchHighlightMarker)] = []
        guard range.length > 0 else { return preserved }
        textStorage.enumerateAttribute(
            EditorFindMatchHighlightMarker.attribute,
            in: range
        ) { value, attributeRange, _ in
            guard let marker = value as? EditorFindMatchHighlightMarker else { return }
            preserved.append((attributeRange, marker))
        }
        return preserved
    }

    /// Restores collected markers *and* their visual attribute after a `setAttributes` pass.
    ///
    /// Both must be restored: `setAttributes` replaces the whole attribute dictionary, so
    /// putting back only the marker would leave a marked range with no visible highlight.
    static func restore(
        _ markers: [(range: NSRange, marker: EditorFindMatchHighlightMarker)],
        in textStorage: NSTextStorage
    ) {
        for preserved in markers {
            let clamped = preserved.range.clamped(toLength: textStorage.length)
            guard clamped.length > 0 else { continue }
            decorate(
                range: clamped,
                role: preserved.marker.role,
                generation: preserved.marker.generation,
                in: textStorage
            )
        }
    }

    private static func decorate(
        range: NSRange,
        role: EditorFindMatchHighlightMarker.Role,
        generation: UInt64,
        in textStorage: NSTextStorage
    ) {
        // Captured at decoration time, not once per query: after a syntax recompute the
        // restore path re-decorates, and the backgrounds underneath are the fresh ones.
        var covered: [EditorFindMatchHighlightMarker.CoveredBackground] = []
        textStorage.enumerateAttribute(.backgroundColor, in: range) { value, subrange, _ in
            guard let color = value as? NSColor else { return }
            covered.append(.init(
                range: NSRange(
                    location: subrange.location - range.location,
                    length: subrange.length
                ),
                color: color
            ))
        }
        textStorage.addAttribute(
            EditorFindMatchHighlightMarker.attribute,
            value: EditorFindMatchHighlightMarker(
                role: role,
                generation: generation,
                coveredBackgrounds: covered
            ),
            range: range
        )
        textStorage.addAttribute(
            .backgroundColor,
            value: backgroundColor(for: role),
            range: range
        )
    }
}
