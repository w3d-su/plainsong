# Drain Recent before an explicit scene navigation

Date: 2026-10-25

## Decision

A picker/OS URL or Files selection that arrives while Recent is restoring waits
for that Recent transition to drain. The scene keeps only the latest pending
navigation; superseded or cancelled waiters receive cancellation without minting
a grant or opening a writer. The Recent operation checks supersession after each
provider suspension, not only Swift task cancellation. Non-Recent scene transitions
keep their existing busy refusal.

If a cancelled Recent install returns a writer, attempt the normal safe close
before releasing its grant. A provider that refuses close keeps its writer,
session, editor binding and admission, read only. A queued replacement cannot
bypass that refusal. An existing Files descriptor may preserve its matching,
already-current grant across successful cleanup; this is not a bookmark restore
or a grant refresh, and revoked scopes still fail normal lease admission.

The production runtime also retains the latest OS delivery while one explicit
open drains. It serially completes the admitted open before the latest pending
one, suppressing stale navigation/errors. Intermediate pending OS deliveries are
superseded. A later OS delivery does not inherit cancellation of the picker
caller. Shutdown blocks new queued deliveries before awaiting its provider. No
second grant/writer operation runs in parallel.

## Why

Cancelling the Recent presenter alone does not end an asynchronous provider
operation. Calling beginTransition immediately discarded the next user-selected
URL, while invalidating a successfully returned Recent writer left a recoverable
clean document unnecessarily read only. Explicit drain ownership fixes both
without reviving denied/revoked bookmarks or dropping an admitted UIDocument.

## Alternatives

Force-clearing the transition or writer ticket can race live UIDocument writers.
Reopening from display paths would invent authority. Retaining every navigation
would replay obsolete user intent. All are rejected. Failed safe close and stale
Files descriptors continue to require explicit reselection or recovery; this
change does not promise automatic restoration of the previous workspace.

## Verification

Required deterministic tests cover picker and OS handoff through the production
runtime, Files through the shell facade, latest pending requests, waiter
cancellation, safe-close success/refusal, and unchanged denied/revoked authority.
Source-bound native results are recorded separately; this document claims no
execution, device acceptance, approval or merge.
