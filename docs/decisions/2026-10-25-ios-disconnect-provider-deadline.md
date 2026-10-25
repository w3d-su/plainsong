# Bound scene disconnect waiting for a provider transition

Date: 2026-10-25. Integration-owner review correction for PR #210.

## Decision

A disconnect waits at most two seconds for an already-owned scene transition.
If the provider is still draining, shutdown reports false and retains admission,
observers, source and grants. It never cancels or drops a live writer to meet the
wait deadline. Normal completion and a later shutdown can safely retire it.

## Why

An unbounded 10 ms poll could suspend scene teardown forever on an unavailable
provider. Returning an honest incomplete shutdown bounds the caller without
creating a second writer or discarding a recoverable draft. Process-wide writer
admission intentionally remains held when a discarded scene retains its writer;
a recreated runtime refuses another writer until safe retirement or app restart.

## Alternatives

Forcibly releasing admission would permit concurrent writers. Changing the
provider operation deadline would not prove its callbacks have drained. Neither
is allowed. A controlled parked-open regression proves the deadline refusal,
retained ticket and subsequent normal retirement.
