import AppKit
import MarkdownCore
import STTextView

/// Retains the model of the last *applied* attribute pass, not an in-flight parse.
/// Recording is constant-time; all range/source/marker checks run only on Replace.
@MainActor
struct EditorReplacePresentationSnapshot {
    let styledText: HighlightedText
    let installation: EditorDocumentBindingInstallation?
    let sourceRevision: Int?

    init(styledText: HighlightedText, coordinator: MarkdownTextViewCoordinator?) {
        self.styledText = styledText
        installation = coordinator?.currentDocumentBindingInstallation
        sourceRevision = coordinator?.currentInstalledSourceSnapshot?.revision
    }
}

@MainActor
extension MarkdownTextViewCoordinator {
    func isReplaceRangeRevealed(_ match: NSRange, in textView: STTextView) -> Bool {
        guard let view = textView as? MarkdownSTTextView,
              view.wysiwygZeroWidthContentStorageDelegate != nil
        else { return true }
        guard let installed = view.replacePresentationSnapshot,
              installed.installation == currentDocumentBindingInstallation,
              installed.sourceRevision == currentInstalledSourceSnapshot?.revision,
              let plan = installed.styledText.foldPlan,
              let storage = MarkdownTextView.textStorage(of: view),
              contains(installed.styledText.range, match),
              contains(NSRange(location: 0, length: storage.length), installed.styledText.range)
        else { return false }

        // The attribute pass already verified its slice. Re-prove it exactly at commit;
        // old offsets alone cannot establish that its owning constructs still exist.
        let rawSlice = (storage.string as NSString).substring(with: installed.styledText.range)
        guard ExactSourceText.matches(rawSlice, NSAttributedString(installed.styledText.text).string) else {
            return false
        }
        // Selection-driven reveal opens only the owners the match touches. A construct
        // nested in an owner but untouched by the match keeps its own fold, so prove the
        // match plus each owner's own chrome, never the owner's whole source range.
        var foldProofRanges = [match]
        for region in plan.regions where overlaps(region.sourceRange, match)
            && WYSIWYGInlineFoldPresentation.includes(region.kind, linkFoldingEnabled: plan.linkFoldingEnabled)
        {
            guard region.isRevealed, contains(installed.styledText.range, region.sourceRange) else {
                return false
            }
            // A link's fold ranges are `[` and the whole `](url "title")`, so this still
            // proves the complete link chrome, including its destination, is revealed.
            for range in region.foldRanges where range.length > 0 {
                guard contains(region.sourceRange, range) else { return false }
                foldProofRanges.append(range)
            }
        }
        var imageProofRanges = [match]
        for image in plan.imageRegions where overlaps(image.sourceRange, match) {
            guard contains(installed.styledText.range, image.sourceRange) else { return false }
            imageProofRanges.append(image.sourceRange)
        }
        return !foldProofRanges.contains { range in
            storage.containsAttribute(in: range) { attributes in
                WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes)
            }
        } && !imageProofRanges.contains { range in
            storage.containsAttribute(in: range) { attributes in
                attributes[WYSIWYGImagePresentationMarker.attribute] != nil
            }
        }
    }

    /// Only the navigation action can remove projection. An already selected but re-folded
    /// match refuses with zero effect; it never silently reveals and commits in one action.
    func revealReplaceImageAfterNavigation(_ match: NSRange, in textView: STTextView) {
        guard textView.selectedRange() == match,
              let view = textView as? MarkdownSTTextView,
              let storage = MarkdownTextView.textStorage(of: view),
              contains(NSRange(location: 0, length: storage.length), match)
        else { return }
        var locations: Set<Int> = []
        storage.enumerateAttribute(WYSIWYGImagePresentationMarker.attribute, in: match) { value, _, _ in
            guard let marker = value as? WYSIWYGImagePresentationMarker else { return }
            locations.insert(marker.sourceRange.location)
        }
        for location in locations {
            // Existing attribute-only reveal removes the complete owning marker and
            // preserves raw selection, viewport, and native undo registration.
            view.revealWYSIWYGImagePresentationIfNeeded(at: location)
        }
    }

    private func overlaps(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    private func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        outer.location != NSNotFound && inner.location != NSNotFound
            && outer.location >= 0 && inner.location >= outer.location
            && inner.length > 0 && outer.length >= inner.length
            && inner.location - outer.location <= outer.length - inner.length
    }
}

private extension NSAttributedString {
    func containsAttribute(in range: NSRange, where predicate: ([NSAttributedString.Key: Any]) -> Bool) -> Bool {
        var found = false
        enumerateAttributes(in: range) { attributes, _, stop in
            if predicate(attributes) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
