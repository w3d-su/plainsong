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
