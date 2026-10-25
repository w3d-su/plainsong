# Retain conflict-copy authority in the production scene

Date: 2026-10-25

## Decision

The production factory creates one conflict-copy coordinator with its existing
concrete scene controller. The runtime retains it, the conflict banner uses its
surface callback, and the root installs the presenter once. Before presenting,
the runtime retires pending command focus and authoring captures without changing
the native source or Undo. Asynchronous external resolution holds the controller
transition fence until its provider read drains, making both orderings of reload
and copy admission explicit.

## Rationale and alternatives

A separate access service, editable source, writer or picker-open route would
split authority and could replace the original conflict. This wiring instead
reuses the coordinator's destination-only lease and the same document store.
Allowing resolution to await without the fence would let a previously started
reload replace source during a copy operation; checking only before the await
cannot exclude that interleaving. No sleep, retry or relaxed assertion is used.

## Validation boundary

Required manifests include all 19 feature cases, including both fence orderings
and a real production-factory surface/copy workflow. Scoped pinned formatting,
strict lint and diff checks are static evidence only. Native tests, actual UI,
current-head CI and physical-device acceptance belong to the integration owner.
No frozen contracts, dependency pins or preview bytes change.
