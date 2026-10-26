# iOS retry and close delivery review repairs

Date: 2026-10-26

## Decision

Keep external reload proposals private while a document close drains its issued
reads. A successful clean close discards the proposal without installing foreign
source or writing provider bytes. If provider close fails, publish the held
proposal after closing ends, only while its entry and access generation remain
current and unfenced. A newer deferred observation supersedes it first.

Preserve stored bookmark bytes through cancellation, coordination deadlines and
transient provider/metadata failures. Only admission failures that demonstrate
unusable authority require reselection. Every refresh failure publication,
including the directory listing's offline path, must still own the latest
request and current grant before changing observer availability.

M0 background time belongs to the active save capture until its completion or
expiration; a writer-busy result does not finish that capture. Create Recent
bookmarks with default information while admitted and resolve without implicit
scope acquisition, retaining explicit start/stop pairing.

## Why

Pending reviews 5650912026, 5650939520 and 5650927486 identified production
reload reentrancy, lost retryable authority, stale refresh publication and early
background-task release. The historical and main-facing branches share these
paths, so the repairs are carried to both. Device and provider acceptance remain
separate from deterministic simulator regressions.

## Alternatives

Keeping a pending proposal in close's retain condition preserves the permanent
close refusal. Publishing it synchronously during the drain dirties the editor
before the closing acknowledgement may rebase it. Burning all failed bookmarks
or publishing every superseded refresh failure converts temporary conditions
into lasting user-visible unavailability. Ending background time on writer-busy
leaves the original capture without time to finish.
