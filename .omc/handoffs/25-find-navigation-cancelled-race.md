# Handoff 25 — Root-cause and fix "failure A": Find navigation superseded by a shared-channel cancel

Read `06-phase3-parallel-overview.md` first, **including its update blocks**: the worktree rule,
the shared xcodebuild lock, the pinned lint, and the "dev Mac is never idle" note. Also read
`24-hosted-replace-ci-flakes.md`, which describes failure A and its history.

## What the new diagnostics show (first real evidence)

Failure A recurred on **#145** (Replace PR G).
- Run: [37262385680](https://github.com/w3d-su/plainsong/actions/runs/37262385680)
- Test: `EditorFindHostedGateTests.testHostedReplaceFromFindChromeUsesTheProductionFallbackCheck`
- Message: "Timed out waiting for Find applies the current match in the hosted editor", then "Chrome focus in the key window must reach its installed editor".

The diagnostics from #142 (`AppTests/EditorFindHostedTimeoutDiagnostics.swift`) printed:

```
currentMatch=Optional({0, 3}) total=Optional(2) queryGeneration=5
focusRequestID=1 focusAppliedID=1 focusSupersededID=0 barVisible=true
appNavigation=Optional(EditorNavigationCommand.cancel(id: 8))
controllerNavigation=Optional(.navigate(EditorNavigationRequest(id: 7, …, selection: {0, 3}, shouldFocusEditor: false)))
diskInspectionPending=false reloadPending=false convergencePending=false
externalPrompt=nil pendingExternalText=false replaceAuthorization=allowed
actualKeyWindow=Optional(342) replaceKeyWindow=Optional(418)
window=418 key=true responder=<field editor NSTextView> queryMounted=true queryOwnsResponder=true
appliedSelection=Optional({0, 0}) selectionMatches=false focusReceiptMatches=true
installation=… pendingNavigation=nil highlightRevision=3 wysiwygInstalled=false markedText=false
```

**What this tells you:**
- **The focus half is fine:** `focusReceiptMatches=true`. The **selection half failed:** the editor's applied selection is still `{0,0}`.
- **Find did its part.** It computed the match and its controller holds `navigate(id 7)`.
- **The App's shared navigation channel holds a newer `.cancel(id: 8)`.**
  - It superseded the Find navigation *before the editor applied it*. The editor has no pending navigation, so nothing retries.
  - Find never republishes id 7.
- **The real `NSApp.keyWindow` (342) differs from the designated test key window (418).** This may matter if any key-window observer emits the cancel.

## Leading hypothesis (verify; don't assume)

Some caller replaced Find's published navigation with a cancel. Candidates on `origin/main`:

1. **`cancelPendingEditorNavigationIfNeeded()`** in `App/AppState+DocumentEditing.swift:506-516`. It cancels **any** `.navigate` still on the channel, Find's included, and does **not** update `editorFindHost.lastPublishedFindNavigationID`. Its callers:
   - `App/AppState+Workspace.swift:468` (`setCurrentDocument`);
   - `App/AppState+WorkspaceReload.swift:23`, `:42` (`clearWorkspaceSearch`), `:91` (`invalidateWorkspaceSearchForWorkspaceGenerationAdvance`), `:603` (`startWorkspaceSearch(…, cancellingPendingEditorNavigation:)`);
   - `App/AppState+DocumentEditing.swift:67` (targeting a session), `:154` (workspace-search activation, forced).

   A workspace reload or watcher refresh can run during hosted setup: fixture writes, autosave, or the #142 quiescence wait. If it calls `clearWorkspaceSearch()` or a generation advance while Find's navigate is published but not yet applied, the Find selection is silently lost.
2. **`cancelPublishedFindNavigationOnSharedChannel()`** in `App/AppState+EditorFind.swift:382-386`. Its callers are the Find lifecycle (`AppState+EditorFindLifecycle.swift` document change, rekey, switch, workspace close, yield) and `AppState+EditorFind.swift:35, 98, 245, 262, 269`. This path *does* update `lastPublishedFindNavigationID`, so check whether any of these fire from a key-window or focus change.
3. **A key-window or focus observer.** `actualKeyWindow ≠ replaceKeyWindow`. Check whether `EditorReplaceKeyWindowObservation`, Find chrome-focus handling, or a window resign/become-key path issues a cancel.

**Why it matters in production.** The window between publishing and applying is short on an idle Mac but real under load. A user who opens Find (⌘F) while autosave's own file event triggers a workspace refresh can see the counter "1 / 2" with no selection or scroll to the match. ⌘G recovers. Treat this as a **product race**, not a test artifact, unless proven otherwise.

## Where you work

- Branch from `origin/main`:
  ```
  git worktree add ../plainsong-find-nav-race -b phase3-find-navigation-cancel-race origin/main
  ```
- Never touch the owner's main checkout. Use new commits only; never force-push.

## Method

1. **Identify the canceller.** In tests only, or behind a DEBUG/test seam, record the call site that sets `editorNavigationCommand = .cancel(...)`. A `#fileID:#line` tag stored next to the command in a test-visible ring buffer works. Then:
   - extend the timeout diagnostics to print the last few navigation-channel writes, with their origin and id;
   - reproduce under load. This Mac is never idle, which helps. Run the hosted Replace and Find classes repeatedly (≥30 runs, `test-without-building -only-testing:`), including `testHostedReplaceFromFindChromeUsesTheProductionFallbackCheck`, until the canceller is captured;
   - if it won't reproduce locally, push the instrumentation to a draft PR and let CI capture it. #141 uploads the xcresult and logs on failure. Ask the owner before re-running CI repeatedly.
2. **Fix at the root, in product code,** once the origin is known. Options to evaluate:
   - Scope `cancelPendingEditorNavigationIfNeeded()` so workspace-search and workspace-reload paths cancel **only navigations they own**. For example, carry an origin (`.find`, `.workspaceSearch`, `.outline`, …) on `EditorNavigationRequest`, or track the last workspace-search navigation id.
   - Or, when a non-Find cancel supersedes a still-current Find navigation for the same document and generation, let Find republish it with a fresh id.
   - Keep every existing safety property:
     - a document switch, rekey, or workspace close must still cancel stale Find navigation;
     - workspace-search activation must still win over an in-flight Find match (the F-gates and the `notifyEditorFindWorkspaceSearchWillNavigate` ordering).
3. **Tests.**
   - A deterministic unit or hosted test that publishes a Find navigation, triggers the identified canceller before the editor applies it, and asserts the final applied selection is the Find match. Alternatively, if cancelling is correct for that event, assert a documented counter-only state.
   - Existing Find and workspace-search fencing tests stay green.
   - Then rerun the repetition loop: 0 failures in ≥30 runs.
4. **Docs.** Add a Decision Log row for any change in navigation-channel semantics. Update `docs/editor-find-gates.md` if an F-gate's evidence or behavior is affected. Update the open-flakes list in `06-phase3-parallel-overview.md`.

## Verification

- EditorKit and MarkdownCore `swift test`.
- Hosted, under the lock: all `EditorFind*`, `EditorReplace*`, workspace-search and workspace-reload suites, plus the F-gate hosted tests.
- `make build`, pinned `make lint`, `git diff --check`.

PR title: `Phase 3: keep Find navigation from being cancelled by unrelated shared-channel cancels` (adjust it once the root cause is known).
