# Restore recent Files access through opaque record IDs

Date: 2026-10-23. IOS-C0-v1 frozen contracts are unchanged.

The production Files browser did not expose the access service's existing recent
records. Its public recent value deliberately omits raw bookmark bytes. Add a
concrete `IOSWorkspaceAccessService.restoreRecent(recordID:)` method that resolves
the service's private stored record and calls the existing bookmark restore path
with its captured scope. Display names, provider identity and UI values never
construct URLs or grant authority.

The service preserves the record ID after bookmark refresh. An in-flight restore
owns an opaque token; removal invalidates it synchronously. A late successful grant
is invalidated and its exact temporary recent row is removed, without file I/O.
Cancellation drains the existing provider operation, retains the prior recent
metadata and cannot publish a new grant. Scope/record/denial failures request
reselection; offline status remains retryable. Removing an already-open record
only removes metadata and does not revoke the document's existing grant.

The App-only recents seam and presenter supply rows and callbacks. Production uses
the same access service already owned by the scene. `openRecent` first proves that
provider identity, reserves the scene transition and safely closes the original
writer. A retained close aborts before any restore, keeping the original source,
binding and admission. The restored grant must pass refresh, cancellation/lifetime
guards and the shared atomic grant-adoption helper before existing `install` may
open a single-file writer. Directory restores publish verified rows without
opening a writer. The shared helper remains the sole setter of `currentGrant`.

A writer returned after cancellation remains admitted and read-only until safe
close, following the existing revocation policy. Cancelling UI presentation cannot
drop such a writer or allow another one to race it. Presenter issuance tokens
suppress late navigation/error callbacks; duplicate taps never queue another open.
Choose Again passes only the captured scope to the existing explicit picker.

The existing unavailable-document Try Again action uses `openSelectedURL`; that
method intentionally returns for the current descriptor, so it does not retry.
The integration owner should replace this misleading action with an explicit
Choose File or Folder Again callback to the existing picker. It must continue to
respect retained-close refusal. A true in-place retry would need a separately
designed store operation that can restore availability while preserving the live
session, unsaved source, pending external observation and revision authority.
Unconditional `resolveExternal(.reload)`, cleared grant guards or a second writer
are rejected alternatives.

This component branch does not wire the Files entry or change shared runtime,
surfaces, status chrome or controller storage. It depends on the recovery base's
`adoptCurrentGrant(_:snapshot:)` helper. Native execution, exact combined-head CI,
new-artifact owner installation, iPad/minimum26, VoiceOver/keyboard and performance
remain separate evidence gates. Previously reported M0 results are retained.
