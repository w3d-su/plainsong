# Files switching responsiveness — 2026-10-15

Base: `origin/main` at `05bcc3054d662e513727bc1572f68abb4c5d64cd`.
Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), arm64.

## Change

The Files List previously read and verified the selected file synchronously on the main
actor. It also published the row selection before loading: a failed load left an unopened
file selected, so the binding could discard a second click on that row as unchanged.
A deterministic invalid-UTF-8 regression failed at that selection assertion before the fix.
The filename-hit test passed before the fix on local macOS 27. Subsequent macOS 15 CI
exposed an additional filename input-path defect, described below; the initial local
result was not evidence that this path worked on every supported system.

Files selections now prepare the same descriptor-verified read off-main. A newer pick or
unmount cancels the previous request. Commit rechecks request ownership, current document,
root, installed workspace capture, and the destination cached/retired session's source
revision, dirty state, bound identity/digest, lifecycle and disk-event generation. A stale
read is retried while the pick remains valid. Only successful activation publishes the
row selection. The existing capture-lag retry bound and mouse/keyboard focus behavior
remain in place. Menu/jump-bar activation stays synchronous and also selects only after
success. Existing anchored activation, conflict arbitration and warm-session ownership
are reused.

Nothing new runs on the typing path. This change does not add an absolute typing-latency
or physical-keyboard/IME acceptance claim.

## Initial local validation (`f2c64b8`)

- Final AppState/Files/focus/drag slice: **328 executed, 2 skipped, 0 failures**. This
  includes all nine new `testNativeFiles*` regressions and the existing Files cases.
  The inactive-key-window mouse test and a case-sensitive-volume case were skipped.
- Launched App: `WorkspaceSearchAcceptanceTests/testFilesSingleClicksKeepSelectionAndEditorInSync`
  passed: **1 test, 0 failures**, six alternating single clicks directly on filename text,
  asserting filename, exact editor source and native selected row after every click.
- MarkdownCore **320**, EditorKit **453 (7 skipped)**, PreviewKit **132**, WorkspaceKit
  **361**: **1,266 executed, 7 skipped, 0 failures** in the four package suites.
- Preview JavaScript: **127 passed** in 16 files.
- Pinned SwiftFormat 0.62.1 and `make lint` pass. SwiftLint reports 352 warnings,
  0 serious; `FilesSelectionDeferral.open` has two complexity/length warnings.
- `git diff --check` passes. Generated project changes are not committed.

The final slice checks failed-read retry, off-main responsiveness under a held read,
newest-pick ownership, cancellation before start and during IO, capture supersession,
dirty cached text preservation, newer external disk observations, and a completed
background save whose source revision did not change.

## Broader-run limits

An earlier full `make test` run, before the final cached-session/save fences, executed
953 App tests (11 skipped) with one failure in
`testHostedApplyingRendersBeforeTheFinalRecheckWhichStillCatchesChangesInThatFrame`:
its transient `Applying…` field was nil. PerformanceTests executed 30 (4 skipped),
0 failures. The UI runner timed out enabling automation mode and ran no UI cases.
The later isolated filename-click UI test started successfully and passed after its
locator was corrected to the native StaticText value; this does not cover the other UI cases.

The isolated failing Find/Replace test passed 8/8 on a clean archive of the base main.
That does not explain or erase the full-run failure. No full-suite-green claim is made,
and no unrelated Find/Replace implementation is changed here.

All Xcode actions used `/private/tmp/plainsong-xcodebuild-test.lock`. App tests and UI
tests used an xcconfig with a separate bundle identifier:
`app.plainsong.sidebar-review.$(PRODUCT_NAME:rfc1034identifier)`. The installed owner App
was neither replaced nor terminated. The separately signed review App contains no test
plugins or fixture-launch environment.

Local, ephemeral evidence is under `/private/tmp/plainsong-sidebar-switch-*`:
`final2.xcresult`/`final2.log`, `ui2.xcresult`/`ui2.log`, `full.xcresult`,
`make-test.log`, `preview-tests.log`, and `lint.log`.
The pre-fix reproduction is `plainsong-sidebar-click-repro.xcresult`; the clean-main
comparison is `plainsong-sidebar-main-baseline.xcresult`. These are local artifacts,
not independently retained performance evidence or current-head CI results.

## PR #166 CI follow-up

CI run `38705047029`, head `f2c64b8d130a4c9bb11ba6075d063c0124a9e12c`, failed on
macOS 15 / Xcode 16.4. App tests executed 955 (14 skipped) with four assertions in the
new filename-click test (two failed clicks, each with timeout plus selection assertion);
UI tests executed 30 with one failure in the new filename-click acceptance test. The
other Files regressions passed. Performance tests executed 30 (4 skipped), 0 failures.
The earlier local transient Find/Replace test passed in this CI run.

The retained UI recording confirms a click at `(81, 193)` over the `z-last.md` filename
while `a-overview.md` stays selected and its exact source stays in the editor. The hosted
window was key at failure. Arrow navigation and a direct table/row-midpoint mouse test
passed, so neither inactive windows nor longer IO timeouts explain these two failures.
The evidence isolates the draggable label hit path; it does not identify SwiftUI's
private recognizer internals.

Draggable labels now forward successful editable-file taps through the same deferred
selection helper as the native List binding. The pending/current-node guard records one
pick when both paths report the same click. Native selection, keyboard navigation,
folder disclosure and drag providers remain in place. Relative-path accessibility IDs and the active file's actual parent breadcrumb
allow the real drag test to distinguish a successful move from an unchanged filename.
The hosted filename test covers automatic and fixed shells, exact text/native selected
row, and one issued/landed request per click.

Local macOS 27 fixed-shell filename clicks also passed before this follow-up, so only
new macOS 15 CI can establish repair of that environment. Follow-up validation is
recorded after execution; no successful CI result is inferred from the local baseline.

A local no-tap control revealed a focus regression in the first simultaneous-tap attempt:
the tap recorded the editor responder, then the native binding acquired the List responder
4 ms later; the commit correctly refused to steal focus based on that outdated snapshot.
The repair lets a duplicate report from the same NSEvent object/node/window settle that
snapshot without issuing another read. It retains the original focus intent; a later
mouse event and a deliberately no-focus pick cannot promote or reset it. Three held-read
regressions exercise those boundaries.

The initial drag harness used touch-style `press`, which did not send a mouse drag.
The corrected macOS `click(...thenDragTo...)` recorded a real preview/drop and moved the
file; a later disclosure assertion raced native spring loading. The final test observes
the real `Files in posts` parent breadcrumb and disappearance of the old root row, plus
unchanged filename and exact source. Nested-file clicking/disclosure is exercised
separately before any move. Interim failures and the no-tap control remain in local
`plainsong-pr166-click-fix*.xcresult`, `plainsong-pr166-no-tap-control.xcresult`, and
`plainsong-pr166-focus-trace.xcresult` artifacts. Temporary NSLog diagnostics were removed.

Local behavior verification after the focus/drag repair:
`plainsong-pr166-click-fix3.xcresult` executed **152 hosted tests (4 skipped), 0 failures**,
and **4 launched-app tests, 0 failures**. The filename test performs six alternating
root-file clicks plus one nested MDX click, checking exact source and editor focus; the
other Files UI test performs a real mouse drag and checks the active file's new parent.
This run preceded extraction of explicit event context and the three new held-read focus
cases. Those final named cases and the full supported macOS 15 result must be assessed
from the matching PR-head run, separately from this local macOS 27 artifact. Final local
artifacts use `plainsong-pr166-final.xcresult` / `.log`; pinned format/lint logs use
`plainsong-pr166-final-format.log` and `plainsong-pr166-final-lint.log` (352 SwiftLint
warnings, 0 serious).
