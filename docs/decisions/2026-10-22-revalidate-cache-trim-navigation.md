# Revalidate each text-element cache trim against the live viewport and selection

The element-cache trimmer captures a viewport, waits for scrolling to settle, then
releases the document tail in 32,768-unit chunks with yields between them. Navigation
can change the viewport and caret during those yields. Cancelling the old task when a
new visible-range report arrives is insufficient: its next chunk can run before that
report cancels it. An attribute-only edit then invalidates text the editor currently
needs, even though no characters or stored attributes change.

The intermittent typing slowdown investigated for #189 exposed this ordering. On
`Fixtures/large-1mb.md`, navigating to caret offset 524,480 after the sixteenth top-based
tail chunk leaves the next captured chunk at `[491906, 524674)`, covering the caret. The
eighteenth chunk, `[459138, 491906)`, covers the live viewport near offset 460,350.
Subsequent native viewport relocation and changing height estimates can send layout far
past the caret. Recreated paragraphs then retain a large cached suffix whose ranges
must be rewritten on every insertion. The gutter's own drawing time does not account
for that sustained cost.

Admit each chunk against current state after `canTrim` returns and immediately before
issuing the attribute edit, on the same main-actor turn. Re-read the real, nonempty
TextKit viewport; missing, empty or inapplicable native ranges refuse the mutation
rather than using the visible-range helper's selection fallback. Retain the prefix
through the viewport plus a prefetch margin of at least 8,192 UTF-16 units. Independently
protect the selected source paragraphs, padded by 8,192 units on both sides. Protecting
whole paragraphs matters because invalidating text far from the caret in one long
paragraph still discards the caret's text element.

`protectedChunk` plans the next safe interval in a descending pass. It shortens a chunk
at either protected boundary, or skips the selected-paragraph band to continue with a
safe chunk before it. The caller advances from the returned chunk's actual location.
An old offscreen caret near the document end therefore preserves its local paragraph
band while allowing cached text between it and the viewport to be released. Invalid
selection offsets refuse admission. Keep cancellation, the settle delay, chunking,
marked-text refusal and the existing writer admission checks; fresh range admission
supplies the correctness boundary when cancellation arrives later.

Visible-range publication and cache-trim scheduling use separate keys. Publish to the
highlighting and scroll reporters only when the visible range changes, but restart the
trim settle delay when either the viewport or actual selection changes. This lets a
selection-protected pass resume after the user collapses a selection without scrolling.
Duplicate selection and attribute observations do not extend the delay. Reset both
keys when attaching to another editor or detaching. The change adds no dependency and
does not change source, stored attributes, selection or Undo semantics.

Alternatives: protecting one prefix through the farther of the viewport and caret
prevents useful middle-cache releases when an old caret remains at the document end.
Caret-only padding misses the rest of a long paragraph. Moving the gutter's fragment
walk from drawing to a completed-layout snapshot prevented draw-time paragraph creation
but did not remove the full slow-run shape; retaining document height during an empty
middle-location viewport relocation reduced the feedback but still left cached-tail
debt. Neither is the retained repair. Increasing settle delays or changing yield timing
only moves the navigation race. Waiting for low machine load cannot establish that a
captured trim range is still safe and would exclude the recorded-load workload that
exposed the problem.
