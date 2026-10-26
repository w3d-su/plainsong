# Capture the cache-trim selection baseline after native layout settles

Date: 2026-10-27

## Decision

The selection-only cache-trim regression samples its viewport and publication
history immediately before collapsing the selection, after the refused-trim
await and a current visible-range report. It still requires the same native
viewport, exactly one additional schedule, resumed trimming and no additional
viewport publication during the measured selection transition.

## Why

PR #221 CI at 74ef88e observed the initial native viewport change from 299 to
286 UTF-16 units during the 400 ms settle wait. The selection still protected
all source and no trim had occurred. Select All schedules native layout; that
legitimate completed layout must be reported before measuring a selection-only
change. Comparing the later state against a sample taken before the await mixed
window setup with the behavior under test.

## Alternatives and validation

The production reporter must continue publishing actual changed native geometry.
No product guard, range assertion, trim budget, timeout or test is removed. The
separate synchronous test still requires exactly one initial publication. Retain
the failed CI log, repeated focused cases, complete EditorKit run and refreshed
iOS source-bound receipt; report exact-head CI separately.
