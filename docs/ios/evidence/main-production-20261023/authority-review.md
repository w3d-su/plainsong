# Plainsong iOS main integration — authority and recovery review

Reviewed source: `1c1685adb7a594f3ecaf81a16d61f5d41e032363`.
Worktree: `/Users/davis._.su/.codex/worktrees/ios-main-production-20261023/blogeditor`.
Scope: read-only source review and SHA-256 verification. No native execution, repository edits, Git mutations, or device acceptance performed by this reviewer.

## Main / #209 integration

The integration commit `af1d895b37f5db1bdfebf539524dc0bf9e12145f` applies the single #209 commit `e13e2bd3d7ebbeda7bdb016620da4548c229aa61` on main `cdb528d4a565cd15e31ddc1b6312b5a45b27236a`. It does not merge the old branch's divergent history. At `af1d895`, all AppIOS, WorkspaceKitIOS and PreviewKit files match #209 exactly. The tree comparison against #209 has only main #195's preview source, scroll tests, generated bundle, decision and the corresponding agent.md changes. Main's preview re-anchoring fix is preserved.

At the reviewed `1c1685a` head, additional differences from #209 are the integration decision/evidence/ledger and the corrected acceptance resource manifest. These do not change the reviewed authority implementation.

One integration defect was found and fixed by the integration owner: `IOSAcceptanceTests/Resources/acceptance-resource-manifest.txt:2` initially pinned #209's older preview bundle (`bba36d54...`) even though main #195's actual bundle was preserved. The corrected entry is `288338b6b287cc18e350759098e8e8694ee030797aabef1b41386866c7fdb760`. A fresh `shasum -a 256 -c IOSAcceptanceTests/Resources/acceptance-resource-manifest.txt` at `1c1685a` reports all 36 records OK. The strict preflight assertions remain intact (`IOSAcceptanceTests/Tests/IOSAcceptanceHarnessTests/ResourceAndLeaseTests.swift:14-32`).

## Authority protections preserved

- `AppIOS/Composition/IOSProductionComposition.swift:28-40`: one access service, one UIDocument store, one native editor and one retained preview; store-issued DocumentSession is attached directly.
- `AppIOS/Composition/IOSDocumentSceneController.swift:234-285`: reserve admission before asynchronous open; install the store-issued identity/session synchronously; a returned writer after grant revocation stays admitted read-only until safe close.
- `AppIOS/Composition/IOSDocumentSceneController.swift:206-225`: retained close keeps the existing session/editor/ticket and refuses replacement.
- `AppIOS/Composition/IOSDocumentSceneController+Lifecycle.swift:7-26,30-58`: only opaque admission is process-wide; true scene shutdown safely flushes/closes before releasing authority. Retained shutdown does not abandon the writer.
- `Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Documents/IOSDocumentLifecycle.swift:5-49,52-69`: close drains the live external-read registry after the write queue, including reads registered by earlier draining reads; source/version/authority and deferred-notice barriers are checked again after provider close.
- `Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Documents/IOSDocumentWriteBarrier.swift:5-8`: deferred external notices remain independent write barriers. Cancellation alone cannot authorize overwrite.
- `Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Documents/IOSUIDocumentStore+External.swift:6-18,42-85`: notices during provider close defer rather than start concurrent reads; deferred barriers are installed before autosave is reconsidered.
- `AppIOS/Composition/IOSDocumentReloadRelay.swift:41-82,117-173`: binding/epoch/access/revision and opaque operation tombstones fence old callbacks. Native external reconciliation and store acknowledgement are synchronous without an await. Marked text defers reconciliation.
- `Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Documents/IOSUIDocumentStore+Save.swift:179-232`: completion identity/generation/sequence checks precede baseline-only rebasing. A captured N acknowledgement cannot replace N+1 source.
- `Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Documents/IOSUIDocumentStore+External.swift:265-301`: Save a Copy creates a new leaf, refuses existing destinations, never rebases or clears the original conflict. If source changes while destination creation is suspended, it can leave a valid older copy and throw `sourceChanged`; callers must not present this as original-file save success or delete an indeterminate result.

No additional source-loss or authority regression was established by this static review. This is not a claim that all native, provider or device gates passed.

## Existing APIs for a small recovery PR

- `IOSUIDocumentStore.swift:80-96` already exposes concrete `recoveryList()` and guarded `discardRecovery`; the frozen IOSDocumentStore protocol does not expose recovery browsing.
- `Recovery/IOSDocumentRecoveryStore.swift:42-76` implements persistent list and load. The list contains the complete immutable IOSRecoveryRecord, including source, baseline, document/revision and record/operation identities.
- `Recovery/IOSRecoveryRecord.swift:10-53` contains persisted metadata. It does not grant access to the original path. Old workspace IDs/generations and `fileURLPath` are historical metadata, never current authorization.
- `Recovery/IOSDocumentRecoveryStore.swift:79-97` refuses discard without confirmed saved bytes and protects newer differing local revisions. The minimal UI should not invoke discard automatically at all.
- Existing `documents.create(at:initialText:lease:)` and scene `install(location, initialText:)` can create and attach a restored new file through the existing UIDocument writer. No FileDocument or alternate source writer is needed.

Prefer injecting narrow closures from the existing concrete store into the production runtime: list records, freshly read a selected record, and restore a selected record. A fresh selection read can re-list and find the requested ID because list already returns complete records, or use a small concrete `loadRecovery(recordID:)` delegate to the store's existing recovery actor. Do not create a second mutable recovery store or expand the frozen protocol merely for the shell. For a direct load delegate, require returned `record.recordID == requestedID`; the current low-level load checks format version but not the filename/record-ID match that list checks.

## Minimum safe restore capture

Use one immutable request value owned by composition. It should carry:

1. A fresh restore/picker issuance UUID. Only the currently pending issuance may complete, and every competing open/create/OS URL delivery, newer restore, cancellation and shutdown retires it synchronously. Use an operation/navigation epoch as well, or equivalent issuance retirement, to reject nil-document A→B→nil and grant A→B→A histories.
2. Recovery identity: recordID, persisted operationID, documentID, revisionVersion and exact source bytes. Keep the record's baseline and origin metadata for readback, but do not reinterpret them as the new document's saved baseline or grant.
3. Optional origin document capture: document identity, exact DocumentSession object, bindingID, revision/version, source bytes and location (workspace identity, access generation and exact relative-path spelling). If there was no document, capture that absence and require it to remain absent until the transition starts.
4. Optional origin grant capture: workspace identity, generation, scope, exact root URL spelling and grantIsCurrent. A same-looking path cannot replace identity/generation checks.
5. After the user picks a destination folder, a separate destination grant/lease capture: grant workspace identity/generation/scope/root plus the selected new leaf descriptor. It must be a current explicit directory grant with a live lease. It is distinct from the historical recovery origin and from the origin document's grant.

The request should capture the installed binding, not whatever editor happens to be current when the picker returns. A newer source revision after the user requested restore must cause a refusal or a fresh user request, never silent retargeting.

## Safe restore sequence

1. List on startup/on user refresh. Selecting a record freshly reads it by opaque ID and displays immutable, read-only source and metadata. Validate its returned recordID and selected metadata; corrupt/missing records produce an error while preserving siblings and live source.
2. Capture the request above before presenting the folder picker. Picker cancellation changes no document, grant, source, file or recovery record.
3. On completion, verify the issuance and every origin document/binding/revision/grant guard before any mutation. Enter one scene transition synchronously and immediately make the current editor non-writable before the first await. `beginTransition()` currently sets only the flag; a new restore implementation must also update editor access immediately, or call the existing close path before any preliminary awaited work. Do not assume the flag itself prevents native typing.
4. Freshly read the same recovery record and open/refresh the explicitly picked directory through the existing access service. Keep this as a provisional destination grant; do not yet replace/invalidate currentGrant. Recheck request, origin revision/session/binding/grant and destination generation after each await. Retire and release only operation-owned provisional authority on failure.
5. Construct a new supported Markdown/MDX leaf inside that directory. Use component-safe filename validation and exact path spelling. A displayed or scanned name is only a candidate; the actual `documents.create` must retain exclusive create-not-overwrite semantics. Avoid the original filename by default, for example use a recovered-copy name; a collision is a safe refusal or a freshly generated distinct name, never overwrite.
6. Call safe `closeCurrent()` while the original admission is still owned. A retained close aborts restore and preserves the old session/binding/ticket/grant and recovery record. Do not forcibly clear installation or admission just because a recovery receipt exists.
7. After safe close returns, require the same restore issuance, unchanged captured origin session version/exact source, no replacement handle, and no active old admission. The old session reference remains available for this check even though clearInstallation removed it from the scene. A close may legitimately update its saved baseline/dirty flag; compare source/revision, not a captured dirty Bool. If a newer source arrived during close, refuse creation. The close path has separately ensured any retired source is durable; never install old recovery text over that newer source.
8. With no await between the final guard and installation setup, adopt the verified destination grant/snapshot and retire only the old grant after its writer safely closed. Invoke existing `install(newLocation, initialText: record.source)` to acquire the new admission, create through the same UIDocument store, and attach the exact returned session. This constructs a new file/session; it does not reconcile old recovery into the old editor.
9. Preserve the record after success and after every failure. Do not call markSaved on an old session, external-reload acknowledgement, resolveExternal(.reload), or discardRecovery as part of this flow. The new file's own persisted baseline is established by documents.create. Any later record-removal UX needs its own explicit confirmation and durable-byte proof.
10. If creation returns a writer after a late grant change, keep the existing install behavior: retain that admitted writer read-only until safe close. Do not drop the handle or invalidate its destination scope in generic catch cleanup. Release a provisional lease only if it has not been transferred to the store; clean up only authority/files this operation demonstrably owns.

Required deterministic cases: restart/list/readback literal Unicode; corrupt sibling preservation; missing/tampered record ID; picker cancel/duplicate/stale completion; document/binding A→B→A; no-document→open→close; N→N+1 while picker/record-read/folder-open/close is parked; retained close; destination collision/revocation; create success attaches the one store-issued session; every failure preserves recovery and cannot write the original; success does not auto-discard.

## Save a Copy: separate PR

`AppIOS/UI/IOSShellFeatureSurfaces.swift:103-105` already provides the composition hook. Install a distinct destination-picker issuance tied to the original identity/binding. Do not reuse openPickedURL for this picker: that method first closes the original, which must remain conflicted/admitted. Use the existing saveCopy/resolveExternal saveCopy route with a destination lease held through safe drain. Success must leave original source, baseline, dirty flag, conflict and autosave barrier unchanged. A destination grant acquired only for copying is released/invalidated only by that operation, without invalidating the original scope. This PR should also cover cancellation, duplicate completion, source-change-during-create and already-existing destination UI outcomes.

## Additional v1 wiring findings

- `AppIOS/UI/IOSShellSceneState.swift:312-315` routes Try Again to openSelectedURL; `IOSDocumentSceneController.swift:129-130` returns immediately for the current location. With a revoked grant, documentLocation refuses instead. Therefore this button does not currently perform a real current-document retry/reselect. A separate repair must preserve close/authority guards rather than clearing them. Existing retained-close availability tests prove preservation, not successful real-provider recovery/regrant.
- Lane 06 exposes restore/recentItems/removeRecent (`IOSWorkspaceAccessService.swift:36,132-139`), but the browser only installs Open/New/Refresh (`AppIOS/Navigation/IOSWorkspaceBrowser.swift:22-47`). Handoff 06:45 requires unavailable recents to offer reselection/removing the recent record without deleting the document. Recents UI remains a separate wiring item.
- The README's fixed v1 frontmatter, image, document Find/single Replace, iPhone pane switching and iPad split surfaces are installed by production surfaces. This is source wiring evidence, not owner acceptance.
- Composition does not implement editor/preview scroll synchronization; the frozen IOSPreviewEvent has no scroll event, and the README's fixed-v1 summary does not explicitly list bidirectional scroll sync. Do not claim it exists; any addition needs a separate scoped design/contract review.

Local static review/checksum, historical native evidence, current exact-head CI, simulator execution and physical owner gates must remain separately labeled. No physical iPad/OS26, VoiceOver, hardware keyboard, typing/render performance or composed-IPA installation result was inferred here.
