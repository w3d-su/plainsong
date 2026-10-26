# Resume retained-close reloads and validate rollback baselines

Date: 2026-10-26

## Decision

Track explicitly requested external reload proposals separately from automatic
observations. A retained close may resume a current explicit proposal even while
the original conflict remains fenced. It must still pass the live operation,
revision, grant and lifecycle checks immediately before native installation.
A new provider-loss fence invalidates the pending proposal; a former request
cannot authorize a later unavailable provider or changed authority.

When an M0 replacement is refused after closing the original document, reopen
that original without replacing its editor identity, source, selection or Undo
history. Compare the reopened source with the retained saved baseline using
exact UTF-8 bytes. A mismatch records local recovery and fences editing/saving
as a conflict; reopening successfully is not proof that the baseline is current.

Frozen C0 declarations and dependency pins remain unchanged. Both repairs stay
inside the existing document and prototype implementations.

## Why

PR #221 review reproduced an explicit conflict Reload that completed while close
was preserving recovery. Publication was held during close, then the conflict
fence also prevented resumption after close retained the writer. A second native
counterexample showed a reopened original loading provider bytes B while its
editor and saved baseline remained A, clean and editable; the next save failed.

## Alternatives

Removing the fenced replay check for every pending proposal would also revive
an older automatic observation after provider availability was lost. Replacing
the retained editor with reopened bytes could discard local source or marked text
and reset native editing history. Keeping a changed original writable preserves
an obsolete baseline and defers failure until the user next tries to save.

## Validation boundaries

Deterministic store/relay and real UIDocument regressions cover the repaired
orderings and refusal boundaries. Complete local native results, negative probes
and exact publication-head CI are separate evidence. Physical-device Files/iCloud,
real Chinese IME, background suspension, performance, accessibility and owner
signing/install acceptance remain open.
