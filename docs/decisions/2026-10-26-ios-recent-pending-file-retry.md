# Retain a pending restored Recent file for retry

Date: 2026-10-26

## Decision

Recent single-file restoration uses the scene's existing picked-file type and
availability checks. A matching Markdown or MDX entry that is downloading or
offline reports the typed cloud failure and retains its already-restored grant
and Files snapshot. Refresh and a later Files selection can reuse that same
single-file authority without another bookmark restore or picker.

The same rule covers a provider becoming unavailable after an available snapshot
but before document open finishes. The failed open releases its operation lease
and writer reservation; retaining the selected scope does not retain a failed
writer or make it writable. Recent feedback uses the existing operation messages
so a download or connection failure does not incorrectly require reselection.

Retention requires the restored grant to remain current and the Recent issuance
to remain active. Cancellation, supersession, shutdown, revocation and unsupported
types still retire an uninstalled scope. The existing exception for a cancelled
Recent and a matching queued Files selection stays separate. A successfully
returned writer still follows normal safe-close draining before scope release;
a retained writer continues to block replacement.

## Why

Recent previously used an available-only location lookup and classified valid
cloud placeholders as unsupported documents. Its error cleanup then invalidated
the restored scope and cleared Files, preventing the Refresh/retry behavior
already supported by explicitly picked single files.

## Alternatives

Minting another grant or restoring again for each retry duplicates authority.
Treating every Recent error as recoverable would preserve cancelled, revoked or
unsupported selections. Starting an automatic download changes provider behavior
and remains outside this integration scope. Reusing the existing classification
and retention helpers keeps the established authority boundary.

## Verification

Twelve required regressions cover downloading/offline snapshots and provider-open
failures, same-grant Refresh/retry, sibling refusal, actual revocation,
unsupported types, cancellation, superseding navigation and transient-failure
feedback. Original required cases and deadlines remain unchanged. Source-bound
native execution, CI and unsigned IPA evidence are recorded separately; this
decision does not claim physical iCloud, owner-device or v1 acceptance.
