# PR L review verification (handoff 29)

Base: PR #152 `1015c12c72ee551d0d449f84b2e4c63cd76461a2`.
Worktree: `phase3-native-macos-polish-review`; additive local commits only, no push.
Verified code/tests commit: `0a6dadb` (the final build/test source tree; later commit is docs only).
Owner checkout and `app.plainsong.editor` are protected. #151’s live file list does not
include `AppState+Workspace.swift`; that file receives only the reviewed focus parameter.

## Width policy

Editor minimum **260 pt**; Preview minimum **260 pt**; Split content minimum **521 pt**.
Window minimum **900 pt**, constant across layout/content and applied to AppKit as well
as SwiftUI. This covers the widest 320 pt sidebar and system split-view allowance.
A requested 720, 735 or 760 pt interactive resize clamps to the production floor.
Inspector default 280 pt, allowed 240–360 pt, handle 5 pt. It collapses at insufficient
column width without changing persisted intent; automatic restoration respects explicit
Hide. Explicit Show attempts to widen by the deficit within `screen.visibleFrame`; if
that cannot fit, intent remains Show while the inspector stays collapsed.

## Focused evidence

- `EditorFindHostedGateTests/testNativeLayoutFixedShellWidthIntentMatrix`
- `EditorFindHostedGateTests/testNativeLayoutSplitShellWidthIntentMatrix`
  **Both passed on macOS 27: 36 frame samples per shell, 72 total.**
  Each covers Source/Split/WYSIWYG × inspector intent on/off × 6 width requests, editor
  and preview floors, measured frame overlap/window containment, widening, explicit Hide
  and explicit Show. Key-window routing uses an injected visibility-object identity seam because a
  hosted background runner may have no real key window; frame/resize evidence is real.
  The test binding substitutes for SceneStorage in a hosted root (which is outside a
  SwiftUI Scene); it exercises the same intent write boundary. Actual scene persistence
  needs the separately signed launched app.
- `InspectorVisibilityTests`: automatic collapse/restoration; restored hidden initial
  state; empty document menu disablement; synchronous close/resign; Show without room.
- `EditorFindHostedGateTests/testNativeFilesArrowSelectionOpensTwoFilesWithoutRequestingEditorFocus`
- `EditorFindHostedGateTests/testNativeFilesSingleMouseClickStillSelectsDraggableRow`
- `NativeSidebarDragTests/testImageDragOffersNodeIDForMovesAndFileURLForEditorDrop`
  The provider keeps plain-text workspace node ID and adds an image file URL. The test
  loads that representation into a private pasteboard and invokes the editor’s real
  `imageFileURLs` decoder. An end-to-end physical image drag remains an owner smoke.

First focused run: 4 passed, 2 failed. The harness used `setContentSize(720)` directly,
which bypasses AppKit’s interactive minimum; production content retained its 900 pt
floor and consequently overflowed the artificially undersized host. The harness now
uses the production `contentMinSize` to model an interactive request and waits for final
column frames. Retained: `/private/tmp/native-ui-focused.xcresult`.
Second build: test-only NSURL existential conversion error; corrected with a checked
NSURL cast. Retained: `/private/tmp/native-ui-focused-v2.xcresult`.
Third run: 6 passed, 3 timeouts; fourth and fifth isolated runs: 0 passed, 3 timeouts
on each. Notification-only key routing did not select the model used by the hosted root;
mouse delivery also targeted an inactive host. Retained: `native-ui-focused-v3`, `-v4`
and `-v5` xcresults under `/private/tmp`. Sixth build: a test-only missing visibility
property was corrected. The final harness injects the same visibility object into the
production root and registry, and skips the mouse test if AppKit cannot make the host
key. This corrects the harness; it does not explain every historical scheduling failure.

Final focused run: **8 passed, 1 skipped, 0 failed**;
`/private/tmp/native-ui-focused-v7.xcresult`. The skipped test is native mouse acceptance
without an active key window. Single-click selection was separately observed in the
foreground development app (z-last.md → kitchen-sink.md). Keyboard arrow selection and
image-provider/real-editor-decoder tests passed. Physical image dragging remains open.

## Preview

`npm test`: 16 files, **127 tests passed**. `npm run typecheck` passed. `make preview-bundle`
regenerates committed `App/Resources/preview` assets from the pinned lockfile.
Contrast on `#2a2a2c`: function `#b184ef` **5.059:1**, link `#6b94ff` **4.983:1**,
comment `#929faa` **5.295:1**; applied in explicit-dark and system-dark palettes.

## Complete local verification

macOS 27.0, arm64, unlocked desktop; all Xcode/build/launch-loop work serialized under
`/private/tmp/plainsong-xcodebuild-test.lock`.

| Check | Result / artifact |
|---|---|
| Full app suite, UI target excluded | **830 passed, 10 skipped, 0 failed** (840 total), `/private/tmp/native-ui-full.xcresult` |
| PlainsongTests | 804 passed, 6 skipped; includes Find/Replace and F6/F7 hosted gates |
| PerformanceTests | 26 passed, 4 skipped; loaded development Mac, no idle acceptance |
| ExportHTML / ExportPDF | 37 / 7 passed, 3 HTML skips |
| MarkdownCore / EditorKit / PreviewKit / WorkspaceKit | 320 / 453 / 71 / 357 total; 1,201 total, 7 EditorKit skips, 0 failures; `/private/tmp/native-ui-package-*.log` |
| Build | passed, `/private/tmp/native-ui-final-build.log`, derived data `/private/tmp/plainsong-native-ui-dd` |
| Pinned lint | SwiftFormat 0.62.1; passed with 329 warnings, 0 serious; `/private/tmp/native-ui-lint-verified.log` |
| Source size and whitespace | New/split view and test files ≤ 400 lines; `git diff --check` passed |

The full result has **217 runtime warnings**: 92 default SceneStorage reads, 92 bindings
outside a Scene, 30 Environment reads outside a View, 2 publishing-during-view-update
warnings and 1 QoS inversion. Hosted roots lack the SwiftUI App scene lifecycle; their
SceneStorage warnings are retained, not represented as real scene persistence evidence.
No constraint exception occurred. Earlier focused runs occurred under high load (about
74); no timeouts remained in final focused/full runs. R22 remains open.

Item mapping: width/intent (1) is the two shell matrix tests above; close/resign and empty
menu (5) are `InspectorVisibilityTests/testCloseAndResignSynchronouslyClearInspectorMenu`
and `testRestoredHiddenIntentStartsHiddenAndEmptyDocumentDisablesMenu`; Files focus/drag
(7) uses the three named sidebar tests above; contrast (8) uses the preview suite and
calculated luminance ratios. Restored intent (9) also uses the visibility tests. Sidebar
OS command gating, tooltip, Edited announcement, static single-file role and unreachable
branch removal are source-reviewed changes; the foreground AX tree confirms static text
for the single-file parent and adjustable handle actions **280 → 290 → 280 pt**. FKA and
VoiceOver interaction remain owner acceptance.

## R17 final-build launch loop and visuals

Final `make build` copied to `/private/tmp/PlainsongNativeReview.app`, ad-hoc re-signed
with the existing entitlements and distinct ID `app.plainsong.native-review-h29`.
**30/30 launches** (30 distinct process IDs) remained alive at the 5-second observation
point with no NSGenericException / Update Constraints loop / uncaught exception:

- 20 workspace-fixture launches: `/private/tmp/native-ui-r17-workspace.json`.
- 10 normal last-file-bookmark restoration launches, no fixture environment:
  `/private/tmp/native-ui-r17-restore.json`. The bookmark was seeded by opening a file in
  this development app's own Documents container; the layout preference was Split.
- No new Plainsong reports in `~/Library/Logs/DiagnosticReports` since the loop began.
  An additional foreground launch verified `native-ui-restore.md`, Split and the inspector
  restored from normal settings/bookmark, without passing a file URL.

The loop ignores AppKit saved-window state (`ApplePersistenceIgnoreState YES`), but uses
the application's normal last-file bookmark. It checks launch stability, not timing or
all UI gates. Only the processes created for this loop were terminated; the owner app
was not launched or terminated.

Screenshots are under `/private/tmp` and **not committed**:

| Evidence | Path |
|---|---|
| Minimum width, Split, inspector requested/auto-collapsed | `/private/tmp/native-ui-final-minimum-split-dark-preview.png` |
| Widened, inspector automatically restored | `/private/tmp/native-ui-final-widened-restored-dark-preview.png` |
| Explicit Hide, widened, still hidden | `/private/tmp/native-ui-final-user-hidden-widened-dark-preview.png` |
| Dark preview code fences | `/private/tmp/native-ui-final-dark-preview.png` |
| Light preview and restored inspector | `/private/tmp/native-ui-final-widened-restored-light.png` |
| Normal last-file restoration | `/private/tmp/native-ui-final-restored-last-file.png` |

Native Window › Move & Resize › Left clamps to the 900 pt floor (approximately 1,802
physical pixels including borders on the Retina display). Return to Previous Size
restores the requested inspector. The earlier foreground workspace screenshots
`native-ui-minimum-split-inspector-requested.png`, `native-ui-widened-inspector-restored-light.png`
and `native-ui-user-hidden-widened-light.png` additionally cover explicit Hide through
shrink/restore. Preview Light/Dark was switched only in the isolated dev app. Native
chrome follows the current light system appearance; a full dark-system chrome screenshot
remains owner acceptance rather than changing the owner's global appearance.

## Owner macOS 27 UI command (prepare only)

Close the owner’s running Plainsong first; this UI target launches `app.plainsong.editor`.
From this worktree on an unlocked macOS 27 desktop:

```sh
make generate
export PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock
lockf -k "$PLAINSONG_XCODEBUILD_LOCK" xcodebuild \
  -project Plainsong.xcodeproj -scheme Plainsong -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/plainsong-native-owner-ui-dd \
  -resultBundlePath /private/tmp/plainsong-native-owner-ui.xcresult \
  -only-testing:PlainsongUITests/EditorFindAcceptanceTests \
  -only-testing:PlainsongUITests/WorkspaceSearchAcceptanceTests test
```

F9 includes `testExactAndTruncatedCountersAreObservablyDistinct` (10,000+ matches) and
`testRepeatedCommandFRefocusesSelectsAllAndLeavesBarOpen`. WS4A includes shortcut/Return/Escape
and click→arrow navigation. Keep this command in R17’s re-verification checklist after
split-view, detail, or routing changes. It was deliberately not run by this agent.

## Remaining external evidence

macOS 15 CI for the new local commits requires the orchestrator to push after review.
The local forced-HStack run is shell coverage on macOS 27, not a macOS 15 execution.
Owner FKA/IME, physical drag, and the above UI target remain owner acceptance. Dev-Mac
load is recorded with hosted/performance results; no idle-machine or absolute performance
acceptance is inferred from a loaded run. R22’s SwiftUI scheduling root cause stays open.

The PR body update is prepared in `native-macos-ui-pr-body.md` for the orchestrator to apply
after review/push; remote #152 metadata was not changed to describe unpushed code.
