import AppKit
import EditorKit
import Foundation

/// Where in-document find reads the editor's selection from, and when that reading is
/// safe to reuse.
///
/// A selection is only ever offsets into one exact source, so both the live probe and the
/// cache carry the document identity and the App-owned revision they came from.
@MainActor
extension AppState {
    func refreshEditorFindCaretFromResponderIfPossible() {
        if let range = appliedEditorSelectionUTF16() {
            editorFindHost.controller.setCaretAnchor(range.location)
        } else if let known = usableCachedEditorSelection() {
            editorFindHost.controller.setCaretAnchor(known.location)
        }
    }

    /// The cached selection, but only while it still describes the current document **and**
    /// the exact revision it was read from.
    ///
    /// Identity alone is not enough: a same-URL Reload keeps the identity while replacing the
    /// text, so an identity-only cache would hand ⌘E an old range to index into new content.
    func usableCachedEditorSelection() -> NSRange? {
        guard let known = editorFindHost.latestKnownEditorSelection,
              known.documentIdentity == activeEditorDocumentIdentity,
              known.sourceRevision == currentDocument.version,
              NSMaxRange(known.range) <= (currentDocument.text as NSString).length
        else {
            return nil
        }
        return known.range
    }

    /// The editor's real selection, caching it for the window-less fallback.
    ///
    /// Reads the editor view itself rather than the last *published* navigation: a published
    /// request can still be pending or rejected inside EditorKit, so trusting it would let
    /// ⌘E copy a range the editor never applied.
    ///
    /// The range is accepted only with matching **provenance**. A native selection is an
    /// offset into whatever source the editor currently holds; during a document switch or a
    /// same-URL Reload that is still the previous content, so stamping it with App's current
    /// identity would let ⌘E index new text with an old range. Identity, installed state, and
    /// the App-owned source revision must all agree before the range is usable.
    func appliedEditorSelectionUTF16() -> NSRange? {
        guard let applied = EditorSelectionProbe.keyWindowAppliedEditorSelection(),
              EditorFindAppliedSelectionPolicy.accepts(
                  applied,
                  identity: activeEditorDocumentIdentity,
                  revision: currentDocument.version,
                  textUTF16Length: (currentDocument.text as NSString).length
              )
        else {
            return nil
        }
        editorFindHost.latestKnownEditorSelection = EditorFindCachedSelection(
            documentIdentity: applied.documentIdentity,
            sourceRevision: currentDocument.version,
            range: applied.range
        )
        return applied.range
    }

    func currentEditorSelectionUTF16() -> NSRange {
        if let applied = appliedEditorSelectionUTF16() {
            return applied
        }
        if let known = usableCachedEditorSelection() {
            return known
        }
        return NSRange(location: 0, length: 0)
    }
}
