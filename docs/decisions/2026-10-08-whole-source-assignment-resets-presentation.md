# Every whole-source assignment routes through one helper that resets presentation bookkeeping

Handoff 26 Part D. `MarkdownTextView.applyIncomingTextIfNeeded` assigned `textView.text`
for an App-initiated text change without the reset added for #144/#150, and the deferred
document-transition retry assigned it the same way. Whole-source assignment erases every
storage attribute. The App text change schedules the ordinary parse that restores
highlighting and folds, but `WYSIWYGImagePresentationController` decides whether its
recorded source survived by a UTF-16 length-plus-endpoints sample. A same-length
replacement with identical first and last 64 units and a mid-document change therefore
kept `appliedMarkers` that no longer existed in storage, the next parse found equal
signatures, and the thumbnail stayed raw forever. A throwaway hosted test had already
reproduced it two of two times (folds 36, markers 0 after 3 s), and the deferred retry
carried the same latent bug for a same-length, same-ends refreshed candidate.

**Fix.** `MarkdownTextViewCoordinator.assignWholeSource` is the single whole-source write.
It holds `isUpdating` over the assignment, restores the previous selection clamped to the
new length, then calls the existing
`discardPresentationBookkeepingAfterWholeSourceAssignment` (fold plan, Replace
presentation snapshot, Find caches, image ownership via `presentationWasReset`). It never
requests a parse itself, because each site knows whether its change already schedules one.
Four call sites route through it: `applyIncomingTextIfNeeded`, the deferred retry,
`applyReconciledSource` and `synchronizeInstalledSource`. `makeNSView`'s first install is
commented as the only intentional direct write. Guards are unchanged: `isUserEditing`, a
pending writer lease and marked text still defer, an exact-match candidate still skips the
write, and no per-keystroke work was added.

**Tests.** `EditorIncomingTextPresentationTests` drives `updateRepresentedTextView` end to
end: a same-length, same-ends, mid-document change restores the marker, folds equal a
fresh parse, and the live Find request is re-materialised in the same update; an identical
candidate performs zero character edits; Å/Å still assigns; the user-editing and
marked-text guards hold, with the marked-text commit's deferred retry proven to discard
bookkeeping and re-materialise the request. A direct `assignWholeSource` pin sits beside
them. A source-level guard in `EditorReplaceLayeringTests` rejects any new stray
`textView.text =` outside the two allowed sites. Hosted:
`testHostedSilentSameLengthReloadRestoresImageThumbnailAndFoldsWithoutAnEdit` (clean
document, no prompt) and
`testHostedSameLengthLocalEditRestoresImageThumbnailAndFoldsWithoutAnEdit` (the #150 setup
shape made deterministic by waiting for `.ready` before the same-length edit). Removing
the bookkeeping call fails three EditorKit tests and the hosted same-length local-edit
test (the thumbnail never rebuilds).

Alternatives: minimal native replacements instead of whole-source writes (rejected: risks
undo, writer-lease, selection and marked-text semantics for no gain); fixing only
`isSameRecordedSource` to compare fully (rejected: full UTF-16 equality on the apply hot
path cost about 35 ms on `large-1mb.md`).
