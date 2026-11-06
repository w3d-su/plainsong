# Present recent Files access through the existing scene

Date: 2026-10-25

## Decision

Files offers a Recent Files and Folders entry. The scene runtime retains one list
presenter over its existing access service. Rows submit opaque record IDs to the
same scene controller's guarded restore path; display names never authorize I/O.
The root owns the sheet. Selecting Choose Again retires that presentation and
issues the existing scoped picker only from its actual dismissal callback.
Presentation IDs reject stale and duplicate callbacks, including cancellation
before the sheet appears. Opening a file navigates only after success and sheet
dismissal; a folder returns to Files with the refreshed existing-provider tree.

Explicit picker requests, OS-open delivery and scene shutdown cancel a pending
recent issuance. Provider work still drains under the original controller's
transition and retains any returned writer until safe close. The unavailable
banner now offers Choose File or Folder Again. Its scope comes from captured
current-grant metadata, including after revocation; it neither derives a URL from
a label nor repeats the old same-location no-op or forces an external reload.

## Rationale and alternatives

A second bookmark/access manager or independent writer would split authority.
Showing a picker before list dismissal can race the active sheet. Delaying with
a timer would not prove dismissal, while an unscoped retry would silently change
folder authority or overwrite newer native source. The same service, explicit
scope, real dismissal callback and safe-close path preserve the existing guards.

## Validation boundary

The required inventory contains 25 recents cases: 18 component cases, six modal
and cancellation cases, and one production-factory Files/tree restore workflow.
The enabled UI plan adds a production recent-list open/dismiss smoke without
assuming or clearing the app's retained records. Source/format/lint checks are
static evidence; native runs, current-head CI, owner Files/iCloud, minimum OS 26,
physical iPad, VoiceOver, external keyboard and performance remain separate gates.
No frozen contracts, dependencies, Mac editor or packaged preview bytes change.
