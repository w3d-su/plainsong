# Preview width changes preserve the anchor's actual pixel offset and skip unchanged geometry

The app-hosted PDF mechanism test observed visible-preview `scrollY` changing from
900 to 899 during unrelated offscreen capture on [#154 attempt 1](https://github.com/w3d-su/plainsong/actions/runs/39470227512/job/118792075452)
and [#189 attempt 1](https://github.com/w3d-su/plainsong/actions/runs/39722453938/job/119638828938).
Neither PR changed preview or export behavior. #180 merged on 2026-10-20 at
08:55:17 UTC, before both failures, and introduced width-triggered source-position
re-anchoring. The historical logs do not record which visible width change triggered
the callback; legacy scroller appearance remains a possible trigger, not a proven one.

The deterministic regression uses source lines 37 and 39 at document tops 900 and
950. At `scrollY = 900`, the lookup at `scrollY + 12` reports source position 37.48.
The inverse mapping computes 911.9999999999999, so unconditional `scrollTo(top - 12)`
requests 899.9999999999999. A browser that quantizes downward moves to 899 even
though neither anchor moved. Source-position lookup also clamps before the first
or after the last anchor, so it cannot generally reconstruct the original pixel
offset. Offscreen PDF capture does not need to mutate the visible preview for this
independent layout callback to violate the test's unchanged-state contract.

Remember the fractional source position, its last observed mapped top, and the
actual pixel offset from that top. On a width notification, read the live mapped
top and do nothing when it is unchanged. When it changes, retain the original pixel
offset and adjust only if the current scroll differs from the resulting target.
Only an actual scroll write claims editor ownership. Updating the observed top
while keeping the offset constant preserves narrow/wide/narrow cycles without
accumulating browser rounding, and also preserves the offset beyond the last source
anchor. Editor-issued smooth scrolls capture the requested destination rather than
the animation's starting scroll position. No bridge message or protocol changes.

`preview-src/test/scroll-sync.test.ts` reproduces 900 to 899 on the unmodified
product using an integer-quantizing scroll mock. It also checks unchanged-layout
ownership, repeated resize cycles, browser-adjusted scrolls and real reflow.
The existing native `PreviewScrollGeometryTests` exercise unchanged editor targets
and real width reflow; `ExportPDFMechanismSpikeTests` checks the visible preview and
first responder throughout offscreen capture. These hosted tests and the PDF test's
0.5 accuracy remain unchanged. The committed preview bundle is rebuilt.

Local validation on 2026-10-22, based on `2138165` (including #193): with the new
test retained and only `src/index.ts` replaced by that base revision,
`npm test -- test/scroll-sync.test.ts -t 'does not scroll or claim'` fails with
`expected 899 to be 900`. Restoring the repair passes all six scroll-sync cases;
the full preview suite passes 154 tests and `npm run typecheck` passes.
The unchanged hosted suites pass 13/13: PDF mechanism 7, preview scroll geometry 3,
and editor/preview coordinator 3, including the original failing PDF test.
EditorKit passes 478 tests (7 opt-in skips), PreviewKit 133, MarkdownCore 323 and
WorkspaceKit 371, all without failures. SwiftFormat 0.62.1's release ZIP matches
the CI SHA-256 `7cb1cb1fae04932047c7015441c543848e8e60e1572d808d080e0a1f1661114a`;
pinned format/lint, SwiftLint and `git diff --check` pass. Hosted execution uses
the shared Xcode lock on an unlocked macOS 27 / Xcode 27 machine with XCUITests
excluded. This local evidence is separate from the PR's macOS 15 CI checks.

Alternatives: relaxing the PDF assertion or waiting longer before its baseline
(rejected: hides an unnecessary production scroll); ignoring small pixel deltas
(rejected: skips real reflow and does not handle clamped source positions);
disabling ResizeObserver re-anchoring (rejected: loses #180's source-position
preservation on window/sidebar resize); gating only on viewport width (rejected:
a changed viewport can leave the anchor unchanged, while a root-width change can
legitimately reflow it); refreshing the offset from the browser's quantized result
after each resize (rejected: accumulates rounding drift).
