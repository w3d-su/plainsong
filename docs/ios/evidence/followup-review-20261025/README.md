# Follow-up review assessment — 2026-10-25

This assessment reopens concrete product findings after the earlier review-fix
handoff. Earlier validation at `0ac80d723563` and its IPA remain historical; they
are not evidence that these follow-up defects were fixed.

| Finding | Assessment and resulting behavior |
| --- | --- |
| #210 HTTP(S) opens twice | Confirmed. Production composition removes its redundant scene opener. PreviewController remains the sole production opener and standalone callers retain their existing platform opening. Actual bridge tests intercept platform dispatch and require one dispatch for each HTTP and HTTPS click. |
| #210 pending/offline iCloud single file reported as unsupported and revoked | Confirmed. Document type and availability are evaluated separately. Downloading/offline return their typed failure while retaining only the still-current explicit single-file grant and Files snapshot for Refresh/retry. Unsupported types, sibling URLs and revoked authority still refuse. |
| #211 restored leaf absent from Files | Confirmed. Restore refreshes the selected destination after create, with issuance, epoch, shutdown and grant fencing. The no-watcher regression and real UIDocument workflow inspect Files before a manual refresh. A failure of post-create refresh explicitly says the file already exists and directs Refresh instead of another restore. |
| #211 public-extension member inaccessible from PlainsongIOS | Not reproduced. The containing extension is explicitly public, so its unqualified member is exported. A separate importing module compiles; the ordinary internal-extension negative control fails as expected. Sources and compiler receipt are in [the probe](../recovery-followup-20261025/README.md). No access modifier change was needed. |
| #218 later Files/picker/OS URL dropped during Recent | Confirmed. Explicit navigation waits behind the active Recent operation and supersedes it. The scene retains the latest pending URL request until provider/writer draining completes. Files uses only its existing matching grant. Runtime also retains the latest later OS delivery without inheriting a canceled picker caller's cancellation. |
| #218 canceled install leaves a clean restored writer read-only | Confirmed. A returned writer goes through the existing safe-close path before grant release. A refused close still retains its writer/session/ticket read-only and refuses replacement. Revoked or denied bookmarks remain refused. |
| #217 conflict-copy behavior | No new defect identified in this follow-up. Only normal upstream merges propagate the #210/#211 repairs; copy authority, overwrite barriers, Undo/draft preservation and provider-drain behavior remain. |

The changes add 20 required app-hosted cases and one required standalone Preview
bridge case. Existing retained-writer cancellation coverage now explicitly makes
safe-close refuse; a separate clean-close case verifies complete cleanup. Other
new cases cover real runtime picker/OS handoff, Files facade selection, last-arrival
semantics, a canceled queued waiter, revoked authority and shutdown boundaries.
No skips, relaxed deadlines, frozen declarations, pins or bridge/resource changes
are introduced. The earlier retry, settings, WebKit navigation-token and main-actor
completion diagnostics are retained.

Related decisions: [links and pending files](../../../decisions/2026-10-25-ios-link-and-pending-file-review.md),
[Recent navigation drain](../../../decisions/2026-10-25-ios-recent-navigation-drain.md).

Validation receipts must identify the exact source and required-case inventory.
Latest-head CI, native simulator tests, unsigned IPA structure and physical-device
acceptance are separate gates. Owner signing/install, real Files/iCloud, physical
Chinese IME/Undo, iPad/minimum iOS 26, accessibility and measured performance remain
open until owner evidence is recorded. No approval or merge is implied.
