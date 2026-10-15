# Files switching responsiveness — 2026-10-15

Base: `origin/main` at `05bcc3054d662e513727bc1572f68abb4c5d64cd`.
Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), arm64.

## Change

The Files List previously read and verified the selected file synchronously on the main
actor. It also published the row selection before loading: a failed load left an unopened
file selected, so the binding could discard a second click on that row as unchanged.
A deterministic invalid-UTF-8 regression failed at that selection assertion before the fix.
The filename-hit test passed before the fix; there is no evidence that dragging caused
this incident, and the native List/drag implementation is unchanged.

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

## Validation

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
