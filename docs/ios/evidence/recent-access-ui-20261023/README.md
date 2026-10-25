# Recent Files access UI component — 2026-10-23

Base: `1c1685adb7a594f3ecaf81a16d61f5d41e032363`.
Branch: `codex/ios-recent-access-ui-20261023`.
This is component/source preparation, not a wired App or executed native result.

## Integration API

- Concrete provider: `IOSWorkspaceAccessService.restoreRecent(recordID: UUID)`.
  The service reads its private stored bookmark and scope; no bookmark is exposed
  to the presenter/UI/log. `recentItems` and `removeRecent` remain the existing APIs.
- App-only seam: `IOSRecentWorkspaceAccess`; its production conformance returns
  the exact same `IOSWorkspaceAccessService` as `workspaceProvider`.
- Scene: `openRecent(recordID:using:)` requires identity with the current workspace
  provider and uses `beginTransition` → safe `closeCurrent` → provider restore →
  fresh workspace snapshot → atomic `adoptCurrentGrant` → existing `install`.
- UI: retain `IOSRecentAccessPresenter(access:openRecent:chooseAgain:didOpen:)`
  in the current runtime and present `IOSRecentAccessList(presenter:)` from Files.
  `openRecent` calls the same scene method, `chooseAgain` opens the existing picker
  with that scope, and `didOpen(.singleFile)` routes to the current document only
  after success. A directory result stays in Files. The UI forwards only record IDs.
- Root must call `cancelPendingOpen()` before another explicit picker/OS-open
  issuance or scene disposal, and reload rows after external access operations.
  An in-flight operation stays busy through safe drain even after UI cancellation.
- Before presenting the readonly recents list, root should reuse the recovery
  base's `IOSProductionRuntime.prepareForReadOnlyPresentation()` to retire command
  focus and authoring captures, rather than adding another focus owner.

The component branch deliberately leaves `currentGrant` private(set). It requires
the recovery integration base's `adoptCurrentGrant(_ grant: IOSWorkspaceGrant,
snapshot: IOSWorkspaceSnapshot) throws`, authored in the original controller file.
That helper is absent on this branch's original base; merge/cherry-pick this
component after the recovery helper before compiling. No ad-hoc picker provenance
or second access service is used to work around that integration requirement.
The recovery helper/runtime APIs are frozen in commit
`a395e5b36a7946b8b0a0608e2ffdb0aba44f260c` and are not duplicated here.

## Controlled test sources

`required-tests.txt` lists every newly added case. Workspace module cases cover
record lookup, captured file/folder scope, display-name nonauthority, stale
bookmark refresh, denied/offline metadata, removed records, parked duplicate,
cancel and remove-during-restore. Their removal assertions count file operations.

App cases cover file and folder success, the same native session/store, retained
original source/ticket, parked duplicate transitions, incoming-root revocation,
old-root/document events after replacement, unrelated-service rejection, cancelled
provider-returned writer retention, and stale/duplicate presenter callbacks.
These are controlled tests awaiting native execution, not owner Files/iCloud PASS.

## Unavailable retry finding and minimal integration change

`IOSShellSceneState.retryOpenUnavailableDocument()` calls `openSelectedURL` with
the current descriptor. `IOSDocumentSceneController.openSelectedURL` intentionally
returns when it already owns that location. This preserves native source/Undo but
makes the displayed Try Again ineffective.

Replace the status-chrome action with **Choose File or Folder Again** and a
runtime/surface callback that presents the existing explicit picker. Preserve the
appropriate single-file/directory scope; do not derive a URL from a label. The
picker result must still use the same scene safe-close path. Retained close must
keep the original writer/source and report refusal instead of opening a new one.
Cancellation of the picker is a no-op for that retained writer.

Do not route this through an unconditional external reload: a dirty unavailable
document, a pending newer editor revision, composing marked text, deferred external
observations and an indeterminate prior close are distinct failure cases. A true
in-place retry would need a narrow store-level operation with identity/revision/
generation and observation-drain guards; it is not implemented in this component.

## Validation boundary

Only owned-path pinned SwiftFormat and static diff/source checks are allowed here.
Pinned SwiftFormat 0.62.1 reports **0/12 files require formatting**. Strict
SwiftLint through stdin (with cache disabled and the repository rules) passes all
**9 new Swift files** with zero output/errors. The first scoped attempt's long UI
status string failed line_length and was shortened through a row presentation
property; its JSON is retained alongside the final source-hashed result:
`/private/tmp/plainsong-ios-main-production-20261023/recents-scoped-lint.json` and
`recents-scoped-lint-final.json`. A prior positional-path strict invocation picked
up the repository's configured included roots and existing warning-level debt;
it is not recorded as an owned-files pass. `git diff --check` is clean.
No XcodeGen, xcodebuild, simctl, Swift build/test, native UI or performance run was
performed. The integration owner must add these required names to the combined
runner's manifest and run the combined modules suite. Files entry/runtime hooks,
minimumOS26/iPad, VoiceOver/external keyboard/performance and new-artifact owner
acceptance remain pending. Existing M0 owner-reported passes are not changed.

Current SwiftUI List/ForEach, ObservableObject/StateObject and view-task lifetime
documentation was fetched with Context7's official Apple SwiftUI source
`/websites/developer_apple_swiftui`; no dependency or frozen API changed.

## Production wiring added on 2026-10-25

The component now follows the Recovery and Save a Copy integration baseline
`0b84d2114bd67c36d8d0c2d64bbf8925814a06b0`, including the grant-adoption
reentrancy repair and current main. The factory installs the presenter with its
same concrete controller and `IOSWorkspaceAccessService`; Files has a toolbar
entry and the production root owns the recent-list sheet. A small presentation
controller retains the sheet issuance ID until actual dismissal. Choose Again
and successful file/folder navigation hand off there once. Early cancellation
retires an unpresented request, and stale callbacks cannot retire a newer sheet.

Unavailable-document chrome now offers Choose File or Folder Again through the
same scoped picker. Revoked current-grant metadata supplies only the file/folder
scope; it grants no access. Cancelling that picker leaves native source, binding,
Undo and dirty state alone. No unconditional reload or same-location open is used.
Explicit picker/OS-open/shutdown routes cancel pending recents, whose provider
operation must still drain. A directory success shows Files; a single-file
success navigates only after successful admission and actual list dismissal.

The feature inventory is now **25 module cases** (18 component + six controlled
modal/source cases + one real production factory workflow), plus one named UI
open/dismiss smoke. All are included in the combined required manifests. Native
execution has not been performed by this author; the integration owner must bind
actual results to the clean implementation head. Historical component-only base
and static results above retain their recorded scope.

## v1 source wiring audit — 2026-10-25

This table is a source audit of the combined candidate. It does not turn existing
or pending native receipts into current-head device acceptance.

| Product path | Source wiring / practical boundary |
|---|---|
| Open Markdown/MDX file or folder | Existing explicit picker → same access service → scene safe close/admission. Recent rows use opaque stored-record IDs. |
| Native source editor and syntax | Factory retains `IOSSourceEditorController` with the existing Markdown syntax tokenizer and one UIDocument session. |
| Live preview | The retained PreviewController renders that native session; no second editable source or preview page per layout update. |
| iPhone source/preview and iPad wide layout | Existing shell pane toggle and width-based split remain wired. Real device layout and keyboard acceptance stay OPEN. |
| Frontmatter, formatting and links | Existing retained authoring controller/surfaces; read-only modal entry retires pending focus and captured commands. |
| Images | Existing staged insertion surface uses the same access service and guarded native edit route. |
| Find and single Replace | Existing authoring panel and scheduler remain wired; new modal presentation retires their captures. |
| Recovered drafts | Recovery list/readback/read-only detail and Restore as New File use the existing recovery store and admitted writer path. |
| Conflict Save a Copy | Destination-only coordinator and picker retain the original source, writer, conflict and recovery record. |
| Recent files/folders | Files toolbar → retained presenter → same service bookmark restore → fresh tree → safe scene admission. Remove Record deletes metadata only. |
| Unavailable access | Choose File or Folder Again uses captured scope and existing picker. Unsafe/retained close refuses replacement and keeps the original writer/source. |
| Preview privacy and MDX | Remote images remain off by default; MDX components remain placeholders. Existing preview bundle/resources are unchanged. |

Bidirectional scroll synchronization is not composed by the frozen C0 facade and
is not claimed by this integration. Cross-file search, Replace All and export are
outside this v1 wiring increment. Current-head native test execution/CI and owner
Files/iCloud providers, IME/Undo/background/relaunch, physical iPad, minimum OS 26,
VoiceOver, external keyboard and performance remain explicit OPEN gates until
separately evidenced. Existing M0 owner-reported results keep their original scope.

Scoped integration static checks: pinned SwiftFormat 0.62.1 reports 0/11 files
requiring formatting. Strict SwiftLint via stdin passes all three newly added
integration Swift files (presentation controller and two test files), with no
warnings. The first lint invocation used an unsupported path flag; subsequent
runs identified a long real-workflow function/tuple, which was split into a typed
fixture. Raw failed and final clean receipts remain in `/private/tmp/`, including
`plainsong-ios-recents-integration-lint-clean-v2-20261025.json`. No tests were run
by the source author; these are formatting/lint receipts only.
