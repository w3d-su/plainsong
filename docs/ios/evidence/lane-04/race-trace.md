# Lane 04 race trace

The tests block on continuations. They do not sleep for a fixed interval.

## Latest edit wins

`testBlockedParseThenEditsRunsOnlyTheLatestRequest`

1. Attach schedules a highlight. The debounce gate releases once, and the fake tokenizer parks inside `tokens(for:)`.
2. Three insertions run while that parse is parked. Each restart cancels the previous debounce and the in-flight task. The tokenizer is still suspended, so a second parse cannot start.
3. The parked result is resumed. Apply rejects it: the task was cancelled and the document version moved.
4. The two cancelled debounces resume and do not enqueue. The last debounce enqueues the only later parse.
5. That request's source is `oneABC`. Its token is the one that sticks. `maximumInFlight` stays 1.

## Reconciliation floor

`testReconciliationFloorRejectsAnAlreadyProducedResult`

1. A parse is parked for `aaaaWWWaaaa`.
2. `installExternalReload` of same-length `aaaaXXXaaaa` raises the presentation floor, cancels the in-flight epoch, and schedules a new parse.
3. The already produced result is resumed and must not paint `strong`.
4. The replacement parse's source is `aaaaXXXaaaa`, and its token paints without another keystroke.

Same-source reload does not clear an existing syntax attribute and does not schedule another parse. A composing buffer returns `.deferred` and keeps the current text.

## Theme and viewport

`testStaleThemeAndViewportResultsAreDiscarded`

A result captured for the previous theme, or for a viewport that has since changed, is resumed before the replacement parse. That result does not paint. The parse scheduled after the change does. Source version and undo do not move.

## Hide, reappear, unmount

`testHideReappearAndUnmountDropLateResults`

Hiding cancels the scheduler epoch. A result resumed after hide does not paint. Showing schedules one new parse. After `invalidateHost()`, a resumed result does not paint and `captureSnapshot()` is nil. Hiding does not go through buffer replacement, so a user undo group from before the hide still undoes.

## Marked text

`testFormatImageAndHighlightDoNotDisturbMarkedText`

`setMarkedText("ㄓ")` is a simulator guard, not Zhuyin acceptance. Format and image `apply` return `.markedText` with the same source, selection, version, and undo flag. A highlight result resumed during the mark does not paint. After `unmarkText()`, the next parse tokenizes the post-composition source.
