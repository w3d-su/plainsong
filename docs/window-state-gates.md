# Window-Scoped State and Native Window Tabs — Gate Specification

> **Status: Windows PRs B1 (#223), B2 (`phase3-window-state-b2`), and C (`phase3-windows-pr-c`) implement §10's B and C rows.**
> D1-0 (`phase3-windows-d1-decisions`) records WD1, WD2, WD3, WD6 (LRU only), WD7, and WD8,
> and splits D1 into D1a, D1b, and D1c. None of D1a, D1b, or D1c is implemented.
> Each workspace window has its own `AppState` façade over a `WindowState` and a
> `WorkspaceRootContext`. Those façades share one `AppDocumentRegistry`. `KeyWindowRouter`
> resolves the key façade. Creation stays guarded until D2, and native tabbing stays off
> until F. A scene gets the app-owned façade whenever no open scene shows it, so closing the
> only window and reopening it keeps working. Checked: all W1 bullets, W2 bullet 5, W3
> bullets 1–6 and 8, and all W5 bullets. W2 bullets 1–3 have a production-path hosted test
> but stay open until two mounted `WorkspaceWindow`s are tested. W0's hosted probes are
> recorded; its owner-smoke boxes stay open. D1a, D1b, D1c, and D2 are not done. WD5 and
> WD6's residency and budget half stay open. §12.2 assigns later `agent.md`
> edits; §9 assigns owner-decision deadlines. Check gates only with named-test or
> owner-recorded evidence in the implementation commit.

Created 2026-10-01 against `origin/main` at `e95ac36` (#132, Export PR E2, which moved
export's ownership check to leaf-path inspection while keeping the Save Copy and mutation
inventories). Windows PR B1 re-verified every `path:line` citation against `282a798`. Moved,
relocated, and changed ones now cite the B1 head, where `AppState`'s storage is split
(§3.2); the rest were unchanged. References: `agent.md` §4, §5, §6.4, §12, §13,
§16, §17; the 2026-06-15 Decision Log row "Defer independent multi-window document state"
(`docs/decision-log.md:51`); `docs/editor-find-gates.md` F7 (dual-window note at
`docs/editor-find-gates.md:789-794`); `docs/editor-replace-gates.md` §5.1 (key-window-only
delivery); `docs/export-gates.md` D5 (ownership inventory).

## 1. Problem, goals, and non-goals

`PlainsongApp` injects one AppState into every WindowGroup window
(`App/PlainsongApp.swift:26`, `:43-45`); B1's `AppState` documents that every window shares
it (`App/AppState.swift:9-12`). Windows mirror one document/root/Find/search/LRU (`agent.md` §5).
New Window is removed (`App/PlainsongCommands.swift:21`); other creation paths remain (W0).

| ID | Goal |
|---|---|
| G1 | Each window owns: its workspace root or single file, its current document, editor selection and scroll, its preview, its sidebar (expansion, selection, Show All Files, Files/Search mode, search query and results), its Find/Replace bar, its banners and prompts, its layout mode, and its error alerts. |
| G2 | Windows that share a file or a root never weaken an invariant in §3.4. |
| G3 | Menus, shortcuts, and the ⇧⌘F hot key act only on the key window. |
| G4 | Each window's workspace or file and current document are restored on relaunch. |
| G5 | Native macOS window tabs, where each tab is a window. |
| G6 | §12 typing latency does not change. The memory budget is restated for N windows and met. |

**Non-goals:** collaboration/sync, multiple host processes, iPad, changing single-window
editing/Find/Replace/preview/WYSIWYG behavior, custom tabs, split panes, a session installed
in two editors (§4.1 b), or bridge changes (`PROTOCOL_VERSION` stays unchanged).

## 2. Baseline (code verified)

### 2.1 App shell and process-wide entry points

| Observation | Evidence | Consequence |
|---|---|---|
| One `@StateObject AppState` for the app. `MenuBarState(appState:)` is built from it. | `App/PlainsongApp.swift:26`, `:29`, `:32-35` | No window identity exists anywhere in the shell. |
| `WindowGroup { WorkspaceWindow().environmentObject(appState) }` | `App/PlainsongApp.swift:43-46` | Every window renders the same state. |
| Each window's `onAppear` reassigns `appDelegate.appState` and `PlainsongAppServices.appState`. | `App/PlainsongApp.swift:47-51` | The last window to appear wins. |
| `onOpenURL` calls `appState.openExternalFile`. | `App/PlainsongApp.swift:52-54` | Apple's `handlesExternalEvents(preferring:allowing:)` documentation says that when no open scene prefers or allows an event, or the modifier is omitted, SwiftUI creates a new scene. Plainsong declares no such modifier, so a Finder Open With or Dock drop while the app runs is expected to create a second, mirrored window. Unverified on this build (W0). |
| Each window's content flushes autosave on `willTerminate`. The app also flushes on any non-active `scenePhase`. | `App/PlainsongApp.swift:55-57`, `:65-68` | N windows mean N flushes at quit. |
| `PlainsongCommands(appState:menuBarState:)` captures the one `AppState`. | `App/PlainsongApp.swift:60-64`, `App/PlainsongCommands.swift:13` | Menu actions have no target window. |
| The `Settings` scene receives the same `AppState`; its panes read `appState.preferences`. | `App/PlainsongApp.swift:70-74`, `App/Views/SettingsView.swift:12-27` | Preferences are app-global. |
| `PlainsongAppServices.appState` is a weak static. | `App/PlainsongAppServices.swift:7-10` | A process-wide singleton. |
| The Carbon ⇧⌘F hot key registers while the app is active. Its action reads `PlainsongAppServices.appState`. | `App/PlainsongApplication.swift:57-75`, `:103-108`, `:142-150` | It toggles search in "the" state, not the key window's. |
| The delegate republishes `appState` and runs the Debug fixture entry points from its `didSet`. Termination asks that one state. | `App/PlainsongApplicationDelegate.swift:13-20`, `:42-54`, `:56-95` | Termination checks cover one state only. |
| The Find hooks are static closures that call `PlainsongAppServices`. The editor selectors call them with no window argument. | `App/EditorFindCommandDelivery.swift:17-33`, `Packages/EditorKit/Sources/EditorKit/EditorFindActionHooks.swift:6-14`, `Packages/EditorKit/Sources/EditorKit/EditorFindSpike.swift:31-46` | A responder-chain Find command cannot name its window. |
| The Find menu falls back to `PlainsongAppServices`. | `App/EditorFindCommandDelivery.swift:36-48` | Same. |
| Format and Find dispatch with `sendAction(_:to: nil, from: nil)`. | `Packages/EditorKit/Sources/EditorKit/EditingBehaviorsSupport.swift:60-62`, `Packages/EditorKit/Sources/EditorKit/EditorFindCommandDispatcher.swift:27-38` | AppKit falls back from the key window to the main window. This is safe only while menu enablement excludes non-workspace key windows (§5.1). |
| `MenuBarState` observes one `AppState` and republishes a deduplicated seven-fact snapshot (Replace and Export added `canReplace` and `canExportHTML` after `e95ac36`). | `App/MenuBarState.swift:10-33`, `:35-43`, `:50-68` | §5.1 keeps this contract and retargets it. |
| `CommandGroup(replacing: .newItem)` holds New File ⌘N, Open… ⌘O, and Open Recent. | `App/PlainsongCommands.swift:21-45` | There is no New Window command (§5.3). |
| View menu: layout cycle ⇧⌘P and Toggle Workspace Search ⇧⌘F. | `App/PlainsongCommands.swift:137-151` | Both must target the key window. |
| `git grep` finds no `handlesExternalEvents`, `openWindow`, `tabbingMode`, `allowsAutomaticWindowTabbing`, `newWindowForTab`, `FocusedValue`, window/document restoration API, or `applicationShouldTerminateAfterLastWindowClosed` outside `agent.md`. | repository search; PR L adds `SceneStorage` for inspector user intent and width in `WorkspaceWindow` | AppKit and SwiftUI defaults apply to window creation. Whether the tab-bar "+" button or Window › Merge All Windows can create mirrored windows today is unverified (W0). |

### 2.2 Precedent: state already keyed by window

| Precedent | Evidence | Reuse |
|---|---|---|
| Find chrome focus is stored per window number, with a seam that stubs only which window is key. | `App/EditorFindHost.swift:40-54`, `App/AppState+EditorFindChromeFocus.swift:20-28`, `:37-43` | It becomes a per-window scalar. The seam pattern carries forward. |
| Find focus and select-all receipts are App-owned because `AppState` is shared. | `App/EditorFindUIState.swift:18-32`, `:176-187` | Keep the receipts per window. They still stop a remounted bar from replaying a token. |
| Responder probes are window-scoped. | `App/EditorFindResponderSupport.swift:43-47`, `:65-71`, `App/AppState+EditorReplaceFocus.swift:23-26` | Reuse unchanged. |
| Replace advances its authority generation on every window's key change (`object: nil`). | `App/AppState+EditorReplaceAuthority.swift:41-48`, `:52-71` | Keep one app-global generation (§3.2). |
| The Replace dispatcher reaches only the key window's editor and never falls through to the main window. | `Packages/EditorKit/Sources/EditorKit/EditorReplaceCommandDispatcher.swift:66-72`, `:113-126` | The model for every document command. |
| `WindowKeyStateTracker` observes key changes of its own window only. | `App/Views/WindowKeyStateTracker.swift:13-28`, `:43-60` | The base for a window-to-state registry. |
| Workspace Search re-reads key status live and has a key epoch. | `App/AppState+WorkspaceSearchUI.swift:122-134` | Reuse. |
| Hosted tests designate the key window. | `AppTests/EditorFindHostedFocusGateTestSupport.swift:22`, `Packages/EditorKit/Sources/EditorKit/EditorSelectionProbe.swift:113-124` | The test pattern for W2–W5. |
| Retired workspace authority is already reference-counted by dependent sessions. | `App/AppStateSupportingTypes.swift:143-218` | The precedent for a reference-counted root security scope. |

### 2.3 Document and session ownership

| Area | Evidence | Today |
|---|---|---|
| `DocumentSession` does not publish `text` or `version`. It supports several text-change subscribers. | `Packages/MarkdownCore/Sources/MarkdownCore/DocumentSession.swift:34-41`, `:90-105` | Two previews can observe one session. Keystrokes do not publish. |
| One binding ID per session; many installations; one writer per session. Publication requires the writer. | `App/AppState+EditorBinding.swift:8-20`, `:116-129`, `:338-350`, `:444-450` | WS3B one-writer authority already spans every installation, in any window. |
| A non-writer installation converges only at its next writer activation (`.synchronize`). | `App/AppState+EditorBinding.swift:433-441` | There is no live cross-view propagation. |
| Reload and Keep Mine synchronize every live installation before finalizing. | `App/AppState+ExternalChanges.swift:147-160` | Already multi-installation. |
| Undo is per text view. | `Packages/EditorKit/Package.swift:13` pins STTextView 2.4.1. That version's initializer gives each view its own `CoalescingUndoManager`, and `STTextView+Undo.swift` returns it unless a delegate supplies one (dependency source, not in this repository). No `undoManager(for:)` exists in `Packages`. | Two editors on one session would hold two undo stacks. |
| One LRU, limit 8. Protected URLs still count toward the limit. Every editor installation is protected. | `App/AppDocumentRegistry.swift:111-115`, `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceSessionLRUPolicy.swift:28-31`, `:94-100`, `App/AppState+WorkspaceSessions.swift:362-381`, `:387-418` | With N windows, only 8 − N warm slots remain (§7.1). |
| Autosave: a foreground task bound to `currentDocument`, background tasks per session, a flush over all sessions. | `App/AppState+Autosave.swift:6-21`, `:23-44`, `:64-93`, `:131-153` | The foreground/background split assumes one current document. |
| Every `WorkspaceWindow` flushes when **any** window resigns key (no `object:` filter). | `App/Views/WorkspaceWindow.swift` (`WorkspaceWindowContent.onReceive`) | N windows mean N flushes per resign. |
| The external-change and missing-file prompts are single values for the current document. Switching clears them. | `App/WindowState.swift:66-75`, `App/AppState+ExternalChanges.swift:42-55`, `App/AppState+Workspace.swift:496-499` | They are per-window projections of per-file state. |
| Indeterminate-write quarantine is per session and blocks `canSave`. | `App/AppDocumentRegistry.swift:146-152`, `App/AppState+DocumentCommands.swift:124-139` | Per file. |
| A namespace mutation sets depth 1, fences the supplied relocation-record sessions, and its end clears **all** fences. | `App/AppState+WorkspaceMutationTransaction.swift:24-48`, `:55-60` | Two concurrent root transactions would clear each other's fences (§3.4 I4). |
| The recovery stores load once, in `init`, from one Application Support directory. A load failure fences file access. Restore is skipped while recovery is pending. | `App/AppDocumentRegistry.swift:227-243`, `App/AppState+DocumentCommands.swift:16-26`, `App/WorkspaceMutationOperationRecoveryStore.swift:786-805`, `App/AppState+WorkspaceMutationRecoveryLoadFailure.swift:5-13`, `:39-51` | Two loaders would read and rewrite the same durable files. |
| "Destination ownership is App-global". | `App/AppState+WorkspaceMutationPreflight.swift:111-113` | The rule this spec keeps. |
| Export checks a leaf-path destination against the Save Copy owner walk and the mutation inventory (`workspaceMutationManagedSessions()` plus owned state URLs). | `App/AppState+MissingFile.swift:374-481`, `App/AppState+ExportDestinationOwnership.swift:37-97` | Export inherits both inventories, so it spans windows once they do. |
| Export's app-private staging root comes from the process environment and home directory. | `App/AppState+ExportAppPrivateRoot.swift:9-26` | App-global, with no window coupling. |
| Known hand-built session lists read one `AppState`: autosave flush, retained-authority collision, physical duplicate, LRU protection, workspace closure, Save Copy candidates, mutation-managed sessions, termination sessions. | `App/AppState+Autosave.swift:7`, `App/AppState+WorkspaceSessions.swift:239-241`, `:298-300`, `:404-406`, `App/AppState+WorkspaceRetirement.swift:92-100`, `App/AppState+MissingFile.swift:483-487`, `App/AppState+WorkspaceMutationPreflight.swift:22-26`, `App/AppState+WorkspaceMutationTextRecovery.swift:442-447` | These are examples, not an exhaustive inventory; I2 defines the migration rule. |
| Hard links and case aliases are detected by physical identity. | `App/AppState+WorkspaceSessions.swift:294-315` | The basis for "same file" (§4.1). |
| Opening a workspace closes the previous one, starts one security scope, and starts one watcher. | `App/AppState+Workspace.swift:335-394` | Per root. |
| Opening a single file closes the workspace. | `App/AppState+Workspace.swift:271-273` | Must become "this window's root". |
| Closing or replacing a workspace retires its sessions, empties `sessionCache`, and resets the LRU. | `App/AppState+WorkspaceRetirement.swift:16-87`, `:235`, `:246` | It also sweeps unrelated warm sessions. Root-scoped release must replace this global closure (§6.2). |
| A watcher event inspects only sessions of that root authority. An unanchored session records membership in at most one installed root. | `App/AppState+Workspace.swift:127-147`, `App/AppState+SessionOwnership.swift:503-550` (early return at `:508`) | Overlapping roots are unsafe (§4.3). |
| `WorkspaceFileTree` bundles the scanned root with `expandedNodeIDs` and `selectedNodeID`. | `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceFileTree.swift:89-100` | Share the snapshot only. Each window owns its entire filtered tree and reload disposition (`App/AppState+WorkspaceReload.swift:284-302`, `Packages/WorkspaceCore/Sources/WorkspaceCore/WorkspacePureTree.swift:155-158`). |
| One last-opened bookmark key and ten recents. Restore runs once per `AppState` and re-saves stale bookmarks. A restored workspace selects its first file, not the last document. | `Packages/WorkspaceKit/Sources/WorkspaceKit/LastOpenedFileStore.swift:4`, `:25-43`, `Packages/WorkspaceKit/Sources/WorkspaceKit/RecentItemStore.swift:4`, `:12-20`, `App/AppState+DocumentCommands.swift:9-37`, `App/AppState+Workspace.swift:389-393` | Per-window restoration needs a list (§6.4). |
| Restoration starts from every window's `.task`, guarded only per `AppState`. | `App/Views/WorkspaceWindow.swift` (`WorkspaceWindowContent.task`), `App/AppState+DocumentCommands.swift:10-11` | Per-window state would restore into every new window. |
| Workspace Search requires a root. Its UI, task, and generation live on `AppState`. | `App/AppState+WorkspaceSearchUI.swift:8-10`, `:57-64`, `App/WindowState.swift:43-51`, `:83-87` | Per window, bound to a per-root generation. |
| One cached `PlainsongPreferences` per `AppState`, with one `onChange` callback. | `App/AppState.swift:94`, `:125-127`, `App/PlainsongPreferences.swift:63`, `:67` | Two instances would not see each other's changes. |
| The layout mode persists under one key. | `App/AppState.swift:314-316`, `:342` | WD9. |
| `App/AppState.swift` was 978 lines at `e95ac36` and 993 at `282a798`. SwiftLint's default `file_length` error is 1000, and `.swiftlint.yml` does not override it. | `wc -l` | B1/B2 must shrink it, not grow it. B1 leaves it at 366 lines. |

Additional consumers of `currentDocument` / `sessionCache` that I2 must migrate:

| Consumer | Evidence | Migration obligation |
|---|---|---|
| `retainMetadataOnlyForRetiredEditorSessions` | `App/AppState+WorkspaceSessions.swift:317-360`; caller `App/AppState+WorkspaceRetirement.swift:247` | Preserve every window's current session and registry-retained session; a root release prunes only its eligible sessions. This clears save fences (`App/AppDocumentRegistry.swift:118-128`), bindings, proofs, quarantine, and detached URLs today. |
| `firstUnretirableExternalConflict` | `App/AppState+WorkspaceSessions.swift:155-171` | Enumerate globally, then filter to the release operation's root when closing one root. |
| `isAddressableExternalResolutionSession` | `App/AppState+ExternalChanges.swift:958-972` | Accept registry-owned sessions, including another window's current session. |
| `canAutosave` membership | `App/AppState+Autosave.swift:141-143` | Registry membership; never one window's cache/current document. |
| `releaseUnreferencedSessionOwnership` | `App/AppState+SessionOwnership.swift:95-117` | Check all windows and retained owners before releasing proof. |
| Search dirty overlays and relevant-edit membership | `App/AppState+CompletionWorkspace.swift:172-180`, `App/AppState+WorkspaceReload.swift:62` | Registry candidates filtered to the query's root; refresh each affected window's search. |

B2 moved every consumer in both tables onto the registry, keeping each consumer's sources,
order, and filters (W1 bullet 3 evidence). The inventories use `AppDocumentRegistry.sessions(from:)`;
the membership checks use `isShownByAnyWindow` and the warm-cache predicates. Release-set
root filtering and scoped release stay with D1b; per-window search refresh stays with D1c.

### 2.4 Packages

| Package | Single-window assumption | Evidence |
|---|---|---|
| WorkspaceKit | None. The LRU policy is a value type. The clone-source registry is process-wide but lock-protected. | `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceSessionLRUPolicy.swift:18`, `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceItemCreationTypes.swift:24-28` |
| PreviewKit | None. Each controller owns its WKWebView, `asset://` handler, render-ID counter, and `invalidate()`. Since #208 a window creates its controller (and WKWebView) the first time it shows the preview pane and keeps it while hidden. | `Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift:45`, `:77-130`, `:249-271`, `App/Views/WorkspaceDetail.swift:10`, `:57-65`, `App/Views/LazyPreviewController.swift:15-27` |
| EditorKit | The Find hooks are static and carry no window. The thumbnail refresh proxy fans out by workspace-relative path, so it belongs to one root. Command routes are keyed per text view, which is safe. | `Packages/EditorKit/Sources/EditorKit/EditorFindActionHooks.swift:6-14`, `Packages/EditorKit/Sources/EditorKit/EditorImageThumbnailLoading.swift:82-85`, `Packages/EditorKit/Sources/EditorKit/EditingBehaviorsSupport.swift:120` |

### 2.5 Tests and evidence infrastructure

| Fact | Evidence |
|---|---|
| 298 direct `AppState(` initializers in `AppTests` at `282a798` (286 at `e95ac36`); 365 substring matches include helper names. Performance tests construct it in three places. | `git grep -E '(^\|[^A-Za-z0-9_])AppState\(' 282a798 -- AppTests`; `PerformanceTests/AppBackedEditorPerformanceTestSupport.swift:84` |
| UI tests pick "the" window as the first hittable one and query identifiers app-wide. | `PlainsongUITests/EditorFindAcceptanceTests.swift:119-129`, `PlainsongUITests/WorkspaceSearchAcceptanceTests.swift:29-37` |
| Accessibility identifiers are not unique across windows. | `App/Views/DocumentJumpBar.swift` (`plainsong.editor.fileName`) |
| Real dual-window key activation has never been verified. | `docs/editor-find-gates.md:789-794`, `docs/decision-log.md:199` |
| The memory gate is 8 warm sessions + 2 live webviews under 400 MB host RSS. Recorded runs: 141.6–149.8 MB host, with about 500 MB across two WebKit helpers (diagnostic, R16). | `PerformanceTests/PerformanceBudgetTests.swift:325`, `:447`, `docs/perf-log.md:76`, `:94`, `docs/risk-register.md:26` |
| The typing-latency gate. | `PerformanceTests/PerformanceBudgetTests.swift:28` |

## 3. State partition

### 3.1 Scopes

| Scope | Owner (names non-binding) | Lifetime |
|---|---|---|
| Per window | `WindowState` | One window or tab. |
| Per workspace root | `WorkspaceRootContext`, reference-counted by windows | First root open → last window release; retained session authority may keep its scope alive (§6.2). |
| Per document file | Entries keyed by `ObjectIdentifier(DocumentSession)` or by canonical URL inside the app-global registry | The session's lifetime. |
| App-global | `AppDocumentRegistry`, `KeyWindowRouter`, services | The process. |

Per-file state is stored in the app-global registry, not in a window: the §3.4 invariants
and the LRU must see all of it. "Per file" is a key, not a separate owner.

### 3.2 Every `AppState` stored property

Re-verified against `282a798` for B1: every stored property `AppState` had there is listed
(121; six were added after `e95ac36`). B1 stores Window rows in `WindowState`, Root rows in
`WorkspaceRootContext`, and File and App-global rows in `AppDocumentRegistry`; `AppState`
forwards each under its old name and access level. `WindowStatePartitionInventory`
(`AppTests/WindowStatePartitionAppTestSupport.swift`) pins this table, and
`WindowStatePartitionAppTests/testAppStateStoresOnlyItsContainers` fails if a stored property
is added to `AppState` itself.

| Properties | Scope | Reason |
|---|---|---|
| `currentDocument`, `documentChangeCancellable` | Window | The window's document and its publish forwarding. |
| `layoutMode`, `wysiwygFallbackMessage` | Window | Per-window layout. New windows inherit the last persisted value (WD9). |
| `editorFocusRequestID`, `editorNavigationCommand`, `editorNavigationChannel` (holds `editorNavigationGeneration`, now a computed property) | Window | They target that window's editor. |
| `editorFindHost`: controller, `ui`, match highlight, selection cache, chrome focus, test overrides | Window, **except** `replaceAuthority.generation` | A Find session binds one installed editor. The generation is advanced by app-global fences too; one app-global monotonic counter supersedes plans at least as often as today. B1: the registry owns the `EditorReplaceAuthorityState` and injects it into the window's `EditorFindHost`. Its `onAdvance` holds one host's callback, so C must fan it out before a second host exists. C must also connect every new `WindowState` (and any new registry or root context) before it can receive input. An unconnected hook stops Debug builds through `UnwiredContainerHook`; in Release it stays a silent no-op, and a fence change would then not advance the generation. |
| `workspaceRootURL` | Window (a reference into a root) | Which root the window shows. |
| `workspaceTree` | Window, including the root node | `showAllFiles` filters the whole tree; reconcile and current-document disposition run per window (`App/AppState+WorkspaceReload.swift:284-302`). Only the scan snapshot is shared. |
| `showAllFiles` | Window | A view filter. |
| `workspaceSnapshot`, `workspaceSearchRootAuthority`, `workspaceInstalledCaptureGeneration`, `workspaceGeneration`, `workspaceReloadTask`, reload hooks (`workspaceReloadPost{Proof,Load,Prepare}Hook`) | Root | One scan, authority, and generation per root. |
| `workspaceAccess`, `workspaceWatcher` | Root, reference-counted | One security scope and one FSEvents stream per root. |
| `workspaceSearchState`, `workspaceSearchUI`, `workspaceSearchFocusKeyEpoch`, `workspaceSearchFocusKeyWindowCheck`, `workspaceSearchTask`, `workspaceSearchEditRefresh`, `workspaceSearchTaskToken`, `workspaceSearchQueryGeneration`, `workspaceSearchRefreshIntent`, `workspaceSearchPostActivationHook` | Window | Each window keeps its own query, results, and focus. The root generation invalidates results. |
| `completionWorkspace`, `completionWorkspaceTask`, `completionWorkspaceBaseCache` | Window | Built from the root snapshot plus the window's current document. |
| `presentedError` | Window | Operation failures go to their initiating window; background failures follow the notice routing below. |
| `externalChangePrompt`, `missingFilePrompt`, `indeterminateFileWriteReconciliationPrompt` | Window projection of per-file state | Shown for the window's own document. The maps behind them are per file. |
| `isSaving` | File | A save belongs to its session. Windows project it. Unpublished since #207. |
| `autosaveTask`, `statisticsTask`, `sessionAutosaveTasks`, `sessionStatisticsTasks` | File | The foreground split assumes one current document (`App/AppState+Autosave.swift:23-62`). Merge into per-session tasks. |
| `editorDocumentBindingIDs`, `editorDocumentBindingSessions`, `editorBindingInstallations`, `editorWriterInstallations`, `pendingEditorSourceInstallations`, `editorDocumentSourceSynchronizers`, `editorDocumentSourceFullComparisonCounts` | File | WS3B one-writer authority must see every installation in every window. |
| `retiredEditorDocumentSessions`, `sessionLifecycleGenerations` | File | Retirement outlives windows. |
| `deferredExternalChangeResolutions`, `externalResolutionIntentCaptures`, `externalReloadTasks`, `externalDiskInspectionTasks`, `pendingExternalReloadApplications`, `nextExternalReloadGeneration`, `externalDiskEventGenerations`, `lastKnownDiskHashes`, `lastKnownDiskModificationDates`, `pendingExternalTexts`, `pendingExternalFileVersions`, `detachedSessionURLs` | File | One disk truth per file. |
| `anchoredSessionFileBindings`, `unanchoredManagedSessionOwnershipProofs`, `editorImageAssetDocumentAuthorities`, `indeterminateSessionWrites`, `indeterminateSessionWriteContexts` | File | Authority and quarantine belong to the file. |
| `sessionCache`, `sessionPolicy` | App-global | One warm set and one LRU (WD6). |
| `workspaceMutationWriteFences`, `workspaceMutationNamespaceDepth` | App-global | One namespace transaction app-wide in v1; the registry holds its affected-session fences and root identity. It fences relocation records, not every session under a root (`App/AppState+WorkspaceMutationPlanning.swift:190-206`). |
| `workspaceMutationRefreshPending`, `workspaceMutationExternalRefreshPending`, `workspaceMutationRefreshRootAuthority` | Root | Each root retains its own deferred watcher/refresh intent, even while another root's transaction runs. Drain all queued roots; today's single-root drain loses an R2 event during R1 mutation (`App/AppState+Workspace.swift:14-24`, `App/AppState+WorkspaceMutationTransaction.swift:62-70`). |
| `workspaceImageAssetInsertionCount`, `editorImageAssetDiscardEventHandler` | Root | Root-owned image-placement fence/callback; namespace begin checks the root's count under the app-wide transaction lock (`App/AppState+WorkspaceMutationTransaction.swift:24-29`). |
| `indeterminateWorkspaceMutationSessions`, `workspaceMutationRecoveries`, `workspaceMutationOperationRecoveryRecords`, `workspaceMutationOperationRecoveryIDsWithUnpromotedText`, `workspaceMutationRecoveryIDBySession`, `workspaceMutationTextRecoveryContexts`, `workspaceMutationTextRecoverySessions`, `workspaceMutationTextRecoveryTasks`, `pendingWorkspaceMutationTextRecoveryRecords`, `pendingWorkspaceMutationOperationRecoveryRecords`, `workspaceMutationRecoveryLoadErrors`, `workspaceMutationOperationRecoveryLoadError`, `workspaceMutationTextRecoveryLoadError`, `workspaceMutationOperationRecoveryLoadFailed`, `workspaceMutationTextRecoveryLoadFailed`, `workspaceMutationReconciliationPrompt` | App-global | The durable stores are single files. One loader, one fence, one prompt. |
| `fileWriteArtifactNotices`, `workspaceTrashCleanupNotices`, `recentItemURLs` | App-global | Registry stores notices with an initiating/home window ID and affected session/root. Show them there, else in a window showing that session/root, else the frontmost workspace window; queue if none. Recents are shared. |
| `shouldRestoreLastOpenedFile`, `didAttemptRestore` | App-global | Restoration runs once per launch, not once per window (§6.4). |
| `preferences`, `isWYSIWYGMechanismHealthy`, `userDefaults` | App-global | One settings source; its single `onChange` fans out to every window (`App/AppState.swift:125-127`). A mechanism failure is process-wide. |
| `fileStore`, `coherentFileReader`, `externalReloadApplicationPreparer`, `lastOpenedFileStore`, `recentItemStore`, `directoryScanner`, `workspaceSearchStreamProvider`, `workspaceSearchLimits`, `workspaceSearchDebounceNanoseconds`, `fileOperations`, `workspaceMutationOperationRecoveryStore`, `workspaceMutationTextRecoveryStore`, `reportedTrashBookmarkAccess`, `editorImageThumbnailAdapter`, `anchoredFileSaveOverride` | App-global | Injected services and a test seam. |
| `editorImageThumbnailRefreshProxy` | Root | It fans out by workspace-relative path. |
| `workspaceSidebarHiddenWindows` | Window | Whether this window's split-view sidebar is hidden, so ⇧⌘F opens Search there (#216). B1 keeps the `NSWindow`-keyed table in the one `WindowState`; C reduces it to this window's flag. |
| `registeredWindows` (B2) | App-global | Each connected `WindowState`, weakly. Every registry inventory includes each window's `shownSession` (§3.4 I2). `AppState.connect(_:)` adds a window after wiring its hooks. |
| `menuEnablementDidChange` (C) | App-global | Save enablement only. Fences, quarantine, and the synchronous `isSaving` guard stay unpublished so they do not wake every window; this subject tells `MenuBarState` to re-read `canSave`. |
| `exportHTMLStatus`, `exportHTMLOperations` | Window | The Export as HTML…/Print banner and operation bookkeeping belong to the origin window, which fences publication when it closes. C decides whether `exportHTMLOperations.lastPrintInfo` (paper settings) stays per window. |

Recovery-banner placement (`App/AppState+WorkspaceMutationRecoveryLoadFailure.swift:5-13`)
has one home workspace window, initially the launch window; the registry retains the global
fence and retargets presentation if that window closes. Background autosave failures use the
same notice routing, preserving their session identity even when it is warm and unseen.

### 3.3 Process-wide statics outside `AppState`

| Static | Evidence | Target |
|---|---|---|
| `PlainsongAppServices.appState` | `App/PlainsongAppServices.swift:7-10` | Removed. `KeyWindowRouter` resolves the key window's `WindowState`; the registry serves app-global needs. |
| Hot-key handler and registration | `App/PlainsongApplication.swift:12-18` | Stays app-global. Its action resolves the key window (§5.1). |
| `EditorFindActionHooks` | `Packages/EditorKit/Sources/EditorKit/EditorFindActionHooks.swift:6-14` | The hooks receive the originating text view's window (an EditorKit API change). |
| `WorkspaceSearchKeyboardSmokeProbe` | `App/WorkspaceSearchSelection.swift:27-38` | Key observations by window; hosted multi-window tests cannot read a last-writer-wins static. |
| `EditorPreviewScrollCoordinator.latestDebugInstance` | `App/Views/EditorScrollBridge.swift:33` | Resolve a designated window's coordinator in hosted tests. |
| `EditorNavigationDebugProbe.shared` | `Packages/EditorKit/Sources/EditorKit/MarkdownTextViewCoordinator+Navigation.swift:301` | Key observations by window/installation in hosted tests. |
| `EditorFindSpike.fireCount`, `lastFireDate` | `Packages/EditorKit/Sources/EditorKit/EditorFindSpike.swift:10-13` | Keep aggregate diagnostics; add originating-window evidence for routing tests. |
| Delegate Debug fixture state | `App/PlainsongApplicationDelegate.swift:5-11`, `:56-95` | App-global creation/cleanup once; explicitly bind fixture actions to the first test window. |

Unchanged: `EditorSelectionProbe.keyWindowOverrideForTesting`
(`Packages/EditorKit/Sources/EditorKit/EditorSelectionProbe.swift:120`), per-view responder
routes (`Packages/EditorKit/Sources/EditorKit/EditingBehaviorsSupport.swift:120`), the locked
clone registry (`Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceItemCreationTypes.swift:24-28`),
and pure `exportAppPrivateRoot` (`App/AppState+ExportAppPrivateRoot.swift:9-26`).

### 3.4 Safety invariants that must stay global

| ID | Invariant | Rule |
|---|---|---|
| I1 | One writer per file. | At most one `editorWriterInstallations` entry per session across all windows (`App/AppState+EditorBinding.swift:444-450`). Under WD1, one window owns the file; asynchronous installation teardown obeys W4. |
| I2 | Every ownership inventory spans all windows. | After B2, nothing outside the registry reads `sessionCache`. Every inventory and membership consumer in §2.3 uses the one registry enumerator (`AppDocumentRegistry.sessions(from:)`) or its window and warm-cache predicates, with explicit operation filters and recovery extras. No `currentDocument` read builds or checks an inventory. Save Copy, export, and mutations refuse any window's owner. The remaining `currentDocument` reads are window-scoped: they read the shared window's own document. After C, nothing outside `WindowState` reads `currentDocument`. Both are grep gates, not counts of lists (W1 bullet 2 for B2, W2's last bullet for C). A façade forwards APIs without reading either store. |
| I3 | Recovery and quarantine fences are global. | Each store loads once; load failure fences every window, pending recovery blocks restoration, and quarantine refuses writes. The per-file save/autosave gate also consults that file's showing-window prompts, or equivalent per-file flags, even for background saves (`App/AppState+DocumentCommands.swift:138`, `App/AppState+Autosave.swift:152`, `:157-161`). |
| I4 | The workspace write fence spans windows that share a root. | The global enumerator supplies affected relocation-record sessions from every window (`App/AppState+WorkspaceMutationPlanning.swift:190-206`); begin fences those sessions (`App/AppState+WorkspaceMutationTransaction.swift:40-48`). One app-global transaction excludes a second (`:24-26`). Root-owned image placement and deferred refresh stay per root (§3.2). |
| I5 | One termination check. | `prepareForTermination` covers the registry, including warm sessions no window shows. |
| I6 | One writer for app-wide bookmarks. | Recents, the restoration store, and the legacy last-opened key. |

## 4. The same file or the same workspace in two windows

### 4.1 Same file (WD1)

"Same file" means the same retained location or the same physical identity: the canonical
session key (`App/AppState+Workspace.swift:397-402`) plus
`hasConflictingPhysicalSessionOwnership` (`App/AppState+WorkspaceSessions.swift:294-315`).
Hard links and case or normalization aliases count. A file is "open in a window" when its
session is that window's current document. Warm LRU sessions belong to no window: a window
may adopt one when no other window shows it.

| Option | Behavior | What it needs | Risks |
|---|---|---|---|
| **(a) Focus the existing window — recommended** | A request that would make file F current in window B while window A shows F brings A (and its tab) to the front. B is unchanged. No error. | A registry lookup from installed file to window, and `makeKeyAndOrderFront` or tab selection. | A sidebar click in B jumps to another window. Every entry point must be routed (W4). |
| (b) Share one `DocumentSession` | B installs a second editor for the session, with its own selection and scroll. | Live per-keystroke propagation to the other installation (today a non-writer converges only at its next activation, `App/AppState+EditorBinding.swift:433-441`). A shared undo model (today each view has its own `CoalescingUndoManager`). IME: marked text in A while B publishes. Per-view WYSIWYG fold and thumbnail presentation over shifting ranges. Find/Replace authority per window over one session (the editor stamp includes window and selection, `Packages/EditorKit/Sources/EditorKit/EditorReplaceCommandDispatcher.swift:10-17`). One external-change prompt resolved from two banners. One autosave. | Cross-window work on every keystroke (§12 typing gate), undo corruption, and the highest review cost. Not for v1. |
| (c) Refuse | An error: "already open in another window". | Least code. | Hostile: the user must find the window. Kept only as the fail-closed fallback when focusing is impossible (the target window is mid-close or has a sheet). |

**Recommendation: (a).** One writer always, one installation once teardown settles (W4);
undo, IME, WYSIWYG, and Find/Replace keep their single-window behavior, with no per-keystroke
fan-out. Main-actor opens serialize; the window releases file ownership only on committed
close (§6.2). Reopening focuses the owner, following the NSDocument convention.

### 4.2 Same workspace root (WD2)

| Option | Behavior | What it needs | Risks |
|---|---|---|---|
| **(i) Shared root context — recommended** | One `WorkspaceRootContext` per canonical root: security scope, watcher, shared scan snapshot/generation, and image-placement fence. The registry transaction fences affected sessions in every window (I4). Each window owns its whole filtered tree, document, and search. Last release retires only this root's eligible sessions (§6.2). | Share `workspaceSnapshot`, build each tree separately, and scope closure by retained authority or installed root membership. Other-root and single-file warm sessions survive; remove selected LRU entries only (`App/AppState+WorkspaceRetirement.swift:92-100`, `:235-247`). A reference-counted scope (precedent: `App/AppStateSupportingTypes.swift:143-218`). | The most code, in D1b (scoped release) and D1c (the shared context). A rename in one window reloads both sidebars, which is the desired result. |
| (ii) Focus the existing window for the same root | One window per root. Opening the root again focuses that window. | The same lookup as WD1. | Tabs lose their main use (several posts of one blog as tabs). "Open in New Window" becomes impossible inside one root. |
| (iii) Refuse | An error. | Least code. | Hostile. |
| (iv) Independent duplicates | Two scans, watchers, and fences for one root. | None. | **Never allowed.** A rename in A would not fence B's session, which violates I4. |

**Decision: (i)**, with WD1 applied per file inside it (owner, 2026-10-29, §9.1). (ii) is
rejected: one window per root rules out several posts of one blog as tabs, the main use
under WD4. D1c shares the context; D1b scopes the last release. B1/B2 and C already give
each façade its own root context, which D1c collapses to one per canonical root.

### 4.3 Overlapping roots and single files inside an open root

The code makes this hard. A watcher event inspects only sessions whose retained location
belongs to its root authority (`App/AppState+Workspace.swift:127-147`). An unanchored
single-file session records membership in at most one installed root
(`App/AppState+SessionOwnership.swift:508`). Decided rules (WD2, 2026-10-29, §9.1):

- Opening a folder that is an ancestor or a descendant of a root open in another window is
  refused: "This folder overlaps a workspace open in another window", with a Show button.
- Opening a single file that lies inside an open root opens it as a workspace document of
  that root. WD1 applies first, then WD7 decides the window. This routing half of W6
  bullet 8 stays open for D2. D1c does not implement it.
- In v1, opening a root containing a file already installed as a single file in another
  window **refuses before root installation**, with a Show button. Do not assume the existing
  membership helper runs at root install: its caller accepts an already-proven proof
  (`App/AppState+SessionOwnership.swift:198-202`), while the production load caller passes
  a new session (`App/AppState+Workspace.swift:457-469`); membership resolution reads one
  root authority (`App/AppState+SessionOwnership.swift:537-538`). Supporting adoption later
  requires explicit root-install and release hooks, including membership revocation.
  Root release still preserves any installed session, even if it retained that root's
  authority before switching to a single-file window. D1c implements the two refusals
  above. The single-file routing bullet stays with D2.

## 5. Command and event routing

### 5.1 Key-window resolution and menu enablement

- **`KeyWindowRouter`** (app-global, main actor) maps each window to its `WindowState`. A
  per-window bridge like `WindowKeyStateTracker` (`App/Views/WindowKeyStateTracker.swift:30-63`)
  registers it. The router publishes `activeWindowState` only on
  `NSWindow.didBecomeKeyNotification`, `didResignKeyNotification`, or window close. When a
  non-workspace window is key (Settings, a panel, an alert), there is no active window:
  document commands disable and never fall back to the main window
  (`Packages/EditorKit/Sources/EditorKit/EditorReplaceCommandDispatcher.swift:66-72`).
- **`MenuBarState` keeps its contract** (`App/MenuBarState.swift:35-43`). It re-subscribes
  when `activeWindowState` changes. It observes the active window plus a deduplicated
  registry/recents signal for file-scoped saving, fences, and quarantine; it re-reads
  `MenuBarSnapshot` on the main run loop and republishes only on change. The snapshot holds the window facts (open document,
  `canSave`, `canReplace`, `canExportHTML`, workspace search, layout title), the app-global `recentItemURLs`, and a new
  `hasActiveWorkspaceWindow`. Background-window UI publishes never reach the menu; a background save
  finishing must still update Save enablement for the active file.
- **Rejected:** whole-object `@FocusedObject` / `focusedSceneObject(WindowState)` restores
  high-churn menu observation. A deduplicated `focusedSceneValue` is an alternative only
  if W0 proves deterministic routing with hosted AppKit key-window seams (§8).

- **Actions resolve their target when invoked**, for example
  `router.activeWindowState?.save()`. `PlainsongCommands` stops capturing an `AppState`
  (`App/PlainsongCommands.swift:13`).
- **Responder-chain commands** (Format, Find) keep `sendAction(_:to: nil, from: nil)`.
  Because enablement excludes non-workspace key windows, AppKit's main-window fallback
  cannot fire. The Find hooks and the App fallbacks
  (`App/EditorFindCommandDelivery.swift:17-48`) resolve the key window's state. The EditorKit
  selectors (`Packages/EditorKit/Sources/EditorKit/EditorFindSpike.swift:31-46`), including
  Escape `cancelFind` (`Packages/EditorKit/Sources/EditorKit/MarkdownSTTextView.swift:103`),
  pass their own window, so a command reaches the window that owns the text view.
- **Carbon ⇧⌘F** stays registered app-wide while active
  (`App/PlainsongApplication.swift:57-85`). `PlainsongWorkspaceSearchKeyAction` toggles
  search on `activeWindowState` only, and still consumes the event when there is none
  (`App/PlainsongApplication.swift:103-108`).

### 5.2 Entry-point routing

"Same rule as Open" means: focus an installed file owner (WD1); a root follows WD2
(reuse its shared context, or focus under the smaller fallback) and §4.3. Use an empty target
(no document and no root), else a new window (WD7). Menu Open targets the key workspace
window. External events use the frontmost workspace window by AppKit z-order, even before
activation; they cannot rely only on `didBecomeKey` having fired. Exactly one window acts, and no blank scene
is left behind.

| Entry point | Today | Target |
|---|---|---|
| Finder Open With, Dock drop, `open -a` (`onOpenURL`) | `App/PlainsongApp.swift:52-54`; SwiftUI may also create a scene (W0) | Same rule as Open. |
| File › Open… ⌘O, empty-state Open (PR L removed toolbar Open) | `App/AppState+DocumentCommands.swift:39-68` | Same rule as Open. The panel is window-modal for the active window, or app-modal when there is none. |
| Open Recent | `App/PlainsongCommands.swift:34-44` | Same rule as Open. |
| Sidebar click | `App/AppState+WorkspaceSelection.swift:35-110` (#201) | Same window. WD1 focus if the file is current elsewhere. |
| Preview relative link | `App/AppState+DocumentEditing.swift:105-110` | A workspace link opens in the same window; an external file follows the Open rule. |
| Workspace Search result | `App/AppState+DocumentEditing.swift:124` | Same window. WD1 applies. |
| ⇧⌘F (hot key and View menu) | `App/PlainsongApplication.swift:142-150` | The active window only. |
| ⌘N New File | `App/AppState+NewFile.swift:10-26` | The active window's root, or the save panel. With no active window, the save panel and then a new window. |
| New Window, New Tab (WD3, WD4) | None | An empty window (§6.1). |
| Debug UI-test fixtures | `App/PlainsongApplicationDelegate.swift:56-95` | The first window. |
| Quit | `App/PlainsongApplicationDelegate.swift:42-54` | App-global (§6.3). |

### 5.3 ⌘N versus New Window (WD3)

`agent.md` §6.4 binds ⌘N to New File. A stock `WindowGroup` binds ⌘N to File › New Window,
which Plainsong removed by replacing `.newItem` (`App/PlainsongCommands.swift:21-25`).

| Option | For | Against |
|---|---|---|
| **(A) Keep ⌘N for New File; add File › New Window ⇧⌘N (and New Tab ⌘T under WD4) — recommended** | §6.4 and `docs/m4-checklist.md` stay valid. No App shortcut collides (`App/PlainsongCommands.swift:25-184`); W0 must also check system-provided menu items. | It departs from apps where ⌘N opens a window. |
| (B) ⌘N for New Window; New File moves to ⌥⌘N | The stock macOS binding. | It breaks §6.4, the M4 checklist, and existing muscle memory. |
| (C) No New Window command | No new command. | Users cannot open an empty window. The tab-bar "+" depends on unverified AppKit behavior. |

## 6. Lifecycle

### 6.1 Opening a window or tab

- An empty WindowState has no document/root, inherits layout (WD9), closes Find, and starts
  in Files mode. New windows never launch restoration (`App/Views/WorkspaceWindow.swift`, `WorkspaceWindowContent.task`).
- Register it with KeyWindowRouter. Create a WKWebView only when a document's preview is
  visible (§7.2); since #208 the first showing of the pane creates it and hiding keeps it
  (`App/Views/WorkspaceDetail.swift:10`, `:57-65`, `Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift:111`, `:128`).

### 6.2 Closing a window or tab

Close interception is a W0 prerequisite: SwiftUI owns the window delegate, so safely
vetoing/deferring `windowShouldClose` needs a probe before relying on it (WD8).
In order (closing a tab is closing a window):

1. **Preflight/refuse:** pending editor source or marked text, an in-flight save or external
   resolution, a namespace mutation, or quarantine refuses or defers the close. Dirty detached,
   untitled, text-recovery, or external-conflict state may stay warm **only** with proven
   registry retention of text, authority, prompts, and LRU protection; otherwise refuse.
   Preflight step 4's release set before revoking installation; compare closure/termination rules
   (`App/AppState+WorkspaceRetirement.swift:26-82`,
   `App/AppState+WorkspaceMutationTextRecovery.swift:300-400`).
2. **Flush:** save a dirty current document when `canAutosave`
   (`App/AppState+Autosave.swift:131-153`). A failed save cancels close. A prompt-blocked
   session is retained under step 1, never saved through that prompt. A saved session stays warm.
3. **Revoke:** use the installation-release path (`App/AppState+EditorBinding.swift:361-405`)
   to release the writer and reconcile the LRU; validate all retention before committing close.
4. **Release:** on the last root-window reference, select registry sessions whose retained
   authority or installed membership belongs to **this root**, excluding any session still
   installed by any window. Preflight only that set; retirement must keep protected sessions.
   Remove only eligible cache/LRU entries; never reset the whole LRU. Scope metadata pruning
   to those retired sessions, preserving fences, bindings, proofs, quarantine, detached URLs,
   other roots' warm sessions, and standalone warm sessions. The global sweep at
   `App/AppState+WorkspaceRetirement.swift:92-100`, `:235-247` cannot be called unchanged.
   Release installed membership explicitly; retained authority/security-scope references
   remain alive until their sessions can safely retire (`App/AppStateSupportingTypes.swift:143-218`).
5. **Cancel** window tasks and invalidate its preview
   (`Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift:249-271`).
6. **Remove** its restoration record on user close only (§6.3).

Failed or fenced eviction candidates remain protected for the pass; an over-limit cache
is allowed (`App/AppState+WorkspaceSessions.swift:362-381`). New File creates a file first
(`App/AppState+NewFile.swift:45-60`); untitled/recovery sessions still require
retention proof. Closing the last window is expected to leave the app running (W7 smoke).

### 6.3 Quitting

- `applicationShouldTerminate` calls one app-global `prepareForTermination()` over the
  whole registry, including warm/protected sessions without a showing window (`App/PlainsongApplicationDelegate.swift:42-54`,
  `App/AppState+WorkspaceMutationTextRecovery.swift:442-447`). A refusal focuses the
  showing/home window; for an unseen warm session, show the retained prompt and error in
  the frontmost workspace window (create a recovery window if none).
- Autosave flushes once. The per-window `willTerminate` observer
  (`App/PlainsongApp.swift:55-57`) moves to the delegate.
- Restoration records are written before AppKit closes the windows. Closes during
  termination do not delete records.

### 6.4 State restoration on relaunch (WD5)

**Today:** one last-opened bookmark, restored once per AppState after recovery, with stale
bookmarks re-saved and first workspace file selected (`App/AppState+DocumentCommands.swift:9-37`,
`Packages/WorkspaceKit/Sources/WorkspaceKit/LastOpenedFileStore.swift:38-40`,
`App/AppState+Workspace.swift:389-393`).

**Proposal:** an app-owned, schema-versioned `WindowRestorationStore` in UserDefaults. It
holds an ordered list of records: an opaque window ID; the kind (workspace or file); a
security-scoped bookmark of the root or file; the workspace-relative path of the current
document; the layout mode; and the tab-group ordinal and index. It is written on open,
document switch, layout change, close (record removed), and quit (snapshot). A launch
coordinator reads it once:

1. **Recovery first.** If recovery records exist or a store failed to load, restore nothing
   else and show recovery in the first window (today's rule, `App/AppState+DocumentCommands.swift:16-26`).
2. Each record resolves its bookmark. The first record restores into the launch window and
   later records open new windows. The current document reopens by relative path;
   otherwise the first file is selected.
3. A missing, unresolvable, or permission-denied item is skipped. One non-modal notice in
   the first window lists the skipped names. There is never an empty extra window and never
   an `NSOpenPanel` prompt (M3: "no bookmark prompts on relaunch").
4. Records that break WD1 or WD2 (one file in two records, overlapping roots) collapse to
   the first.
5. **Migration:** with no store, the legacy single bookmark becomes one record, so M1's
   "quit & relaunch restores last file" keeps passing.

**Mechanism risk.** SwiftUI/AppKit are expected to recreate windows when the system
setting "Close windows when quitting an application" is off; W9 must prove this behavior. W9's first bullet must prove exactly
one window per record with that setting on and off. `restorationBehavior(_:)` is believed
to need macOS 15, while the deployment target is macOS 14, so the probe must find a
macOS 14 path (for example `WindowGroup(for:)` presented values as record keys, or AppKit
`isRestorable`).

### 6.5 Native tabs (WD4)

- Each AppKit tab is a window with its own WindowState; no custom tab model.
- C disallows tabbing via `tabbingMode = .disallowed` or `allowsAutomaticWindowTabbing = false`
  and guards creation paths. F enables `.automatic` (system Prefer tabs); ⌘T joins the key group.
- Merge/move/drag preserve the window object and state (W0); titles follow §8, hidden tabs
  follow §7.2 residency, close follows §6.2, and E restores tab-group order (§6.4).

## 7. Performance and memory

### 7.1 Warm-session LRU (WD6)

The LRU stays **global**: 8 warm sessions plus every installed current document. Today
protected entries count toward the limit
(`Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceSessionLRUPolicy.swift:94-100`), so
N windows would leave 8 − N warm slots. PR D1a adds a separate `installedURLs` input:
installed entries do not count toward warm capacity and cannot be evicted. Keep
`protectedURLs` counting toward capacity for failed-eviction, fenced, quarantined, and
retired candidates (`App/AppState+WorkspaceSessions.swift:372-418`); verify both policies
with named tests. Do not subtract the whole protected set from capacity. A per-window LRU is rejected: it costs 8·N
sessions, and a session warm in two windows would still need one cross-window owner.

### 7.2 Preview residency (WD6)

- **Lazy:** no controller or WKWebView until a window shows a document with the preview
  visible.
- **Visible previews are always live.**
- A window whose preview is not visible (source-only layout, miniaturized, a background
  tab, or occluded per `NSWindow.occlusionState`) keeps its WKWebView for a 30-second
  grace period. Beyond the two most recently visible hidden previews, it is torn down with
  `invalidate()` after its top visible line is saved. Showing it again shows the editor
  at once and recreates and renders the preview (one index load plus one cold render).
- **Safety:** `invalidate()` removes the bridge handler and clears the callbacks
  (`Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift:262-266`), so a torn-down
  preview cannot deliver a checkbox toggle. Render IDs restart per controller
  (`Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift:45`). That is safe
  because `checkboxToggled` requires the controller's latest render ID (`agent.md` §7.3).

### 7.3 Restated §12 memory budget (proposal)

< 400 MB host RSS: 8 warm sessions, 4 windows, 2 visible settled previews, 2 hidden windows
past teardown. Record host delta per preview and helper RSS diagnostics in
`docs/perf/YYYY-MM-DD-<slug>.md`;
keep the two-webview test (`PerformanceTests/PerformanceBudgetTests.swift:325`).

### 7.4 Typing latency

WD1 adds no per-keystroke cross-window work. DocumentSession still does not publish text
(`Packages/MarkdownCore/Sources/MarkdownCore/DocumentSession.swift:34-41`); WindowState forwards
only its document's publishes (today AppState forwards app-wide, `App/AppState.swift:263-268`).
The registry publishes no text changes; menus observe deduplicated facts. W12 measures this.

## 8. Accessibility and UI-test implications

- **Titles:** PR L (§10.1) moved the title to SwiftUI `navigationTitle` /
  `navigationSubtitle`: document name, else root, else Plainsong, with the root (or a single
  file's parent folder) as subtitle. `WindowMetadataAccessor` keeps the represented URL and
  edited dot (`App/Views/WindowMetadataAccessor.swift`). `AppState.windowTitle` no longer
  drives the window; C removes it with the singleton. Still open for C/F: append the root
  name for duplicate filenames, and tab titles follow.
- **Selectors:** identifiers stay stable but queries scope to a uniquely titled window.
  App-wide queries/first hittable window in `PlainsongUITests/EditorFindAcceptanceTests.swift:119-129`
  and `PlainsongUITests/WorkspaceSearchAcceptanceTests.swift:29-37` must change.
- **Hosted tests:** designate a key window (`AppTests/EditorFindHostedFocusGateTestSupport.swift:22`)
  and window-specific probes (§3.3). Real activation requires interactive XCUITest
  (`docs/decision-log.md:199`), coordinated with Replace I/Export G acceptance (§10).
- **VoiceOver/FKA:** distinct titles, each window's last-control focus restored; ⌘` cycles
  windows, and each Find chrome owns its focus report. W13 records the smoke.

## 9. Owner decisions

Deadlines that drove the records: WD4 and WD9 before PR C (recorded 2026-10-28); WD1,
WD2, and WD6 (LRU) before D1, and WD3, WD7, and WD8 before D2 (recorded 2026-10-29, §9.1).
Still open: WD5 before E, and WD6's residency and §7.3 budget before G. Silence, an
implementation, or green CI is not a decision.

| # | Question | Options | Recommended default | Consequences |
|---|---|---|---|---|
| WD1 | The same file in two windows | (a) focus the existing window; (b) share one session; (c) refuse | **(a)**, also for sidebar clicks and preview links | I1 holds trivially. No undo, IME, or typing-path change. (b) needs its own spec. |
| WD2 | The same workspace root in two windows | (i) shared reference-counted root context; (ii) focus the existing window; (iii) refuse | **(i)**, plus refusal of overlapping roots and a root that contains an installed standalone file | D1c shares the snapshot and keeps each whole tree window-owned; D1b scopes release to one root. (ii) is rejected (§9.1): it rules out several posts of one blog as tabs. |
| WD3 | ⌘N versus New Window | (A) ⌘N New File + ⇧⌘N New Window; (B) ⌘N New Window; (C) no command | **(A)** | §6.4 gains rows; none move. |
| WD4 | Are tabs in scope for this line? | Yes, as PR F; defer (then set tabbing to disallowed so tabs cannot mirror) | **Yes**, enabled in F with `.automatic` and ⌘T | Decide before C; C disallows tabs/extra scene opens until guarded D2 routing exists; F waits for D2. |
| WD5 | Restoration | Restore every window and tab with document and layout; restore only the frontmost (today's single bookmark); follow the system setting only | **Restore every window**; skip missing items with one notice; recovery first | Needs the W9 mechanism probe. |
| WD6 | Preview and memory policy | Lazy, visible always live, two hidden within a 30 s grace; always live with a window cap; per-window LRU | **The first**, plus a global LRU of 8 warm + installed and the restated §12 budget (§7.3) | Re-showing a torn-down preview costs one cold render. |
| WD7 | Where an external open lands | A new window unless the frontmost workspace window is empty; always that window; always new | **Reuse an empty frontmost workspace window, else new** | Resolve z-order before activation; WD1/WD2 take precedence. |
| WD8 | Closing a window whose document cannot be saved safely | Refuse every blocked close; retain protected state after close; hybrid | **Hybrid (§6.2): refuse transient/quarantine states; retain stable blocked sessions only with proof** | Switching documents already keeps dirty/conflicted sessions warm and restores prompts (`App/AppState+Workspace.swift:496-499`). Closing can do likewise; last-root release must preserve authority and fences. An unseen protected session still participates in termination. W0 proves interception; absent retention proof, refuse. |
| WD9 | Layout mode and Find query scope | Per window, new windows inherit the last persisted layout; global | **Per window** | M2's "layout restored on relaunch" moves into the WD5 records. |

### 9.1 Recorded decisions

Only a row here is a decision. WD5 is still open. WD6's row is the LRU half only; its
residency half and the §7.3 budget stay open until G.

| # | Decision (owner, date) | Record |
|---|---|---|
| WD1 | Focus the window that already shows the file, including a sidebar click and a preview link. Refusal is only the fail-closed fallback when focusing is impossible. Implemented in D2. (Owner, 2026-10-29: the recommended default.) | `docs/decisions/2026-10-29-windows-wd1-focus-existing-window.md` |
| WD2 | One shared, reference-counted root context per canonical root. Refuse a folder that overlaps a root open in another window, and refuse a root that contains a file installed as a standalone file in another window. (ii) is rejected: it rules out several posts of one blog as tabs, the main use under WD4. D1c shares the context; D1b scopes release. Single-file routing inside an open root stays with D2. (Owner, 2026-10-29: the recommended default.) | `docs/decisions/2026-10-29-windows-wd2-shared-root-context.md` |
| WD3 | ⌘N stays New File. New Window is ⇧⌘N. New Tab is ⌘T under F. Implemented in D2; until then there is no New Window command, `WindowOpenAdmission` is unchanged, and tabbing stays disallowed. (Owner, 2026-10-29: the recommended default.) | `docs/decisions/2026-10-29-windows-wd3-command-n-stays-new-file.md` |
| WD4 | Tabs are in scope for this line. PR F enables native window tabs with `.automatic` tabbing and ⌘T. Until F, PR C disallows tabbing, so no tab can mirror another window. (Owner, 2026-10-28: the recommended default.) | `docs/decisions/2026-10-28-windows-wd4-tabs-in-scope.md` |
| WD6 | LRU half only: one global LRU of 8 warm sessions plus every installed document. Installed documents do not count toward capacity and cannot be evicted; other protected entries still count and cannot be evicted. Do not subtract the protected set from capacity. D1a implements this. Residency and the §7.3 budget stay open until G. (Owner, 2026-10-29: the recommended default for this half.) | `docs/decisions/2026-10-29-windows-wd6-global-lru-of-warm-and-installed.md` |
| WD7 | An external open reuses the frontmost workspace window when it is empty; otherwise it opens a new window. WD1 and WD2 take precedence. Implemented in D2. (Owner, 2026-10-29: the recommended default.) | `docs/decisions/2026-10-29-windows-wd7-external-open-reuses-an-empty-window.md` |
| WD8 | Hybrid (§6.2): refuse transient and quarantine states; keep a stable blocked session after close only with registry retention proof, otherwise refuse. Implemented in D2. Last-root release (D1b) preserves authority and fences for a session this rule keeps. (Owner, 2026-10-29: the recommended default.) | `docs/decisions/2026-10-29-windows-wd8-hybrid-blocked-close.md` |
| WD9 | Layout mode and the Find query are per window. A new window starts with the last persisted layout. (Owner, 2026-10-28: the recommended default.) | `docs/decisions/2026-10-28-windows-wd9-per-window-layout-and-find.md` |

## 10. Review-sized PR split

Each PR branches from then-current `origin/main` and targets `main`; the maintainer
squash-merges. Coordinate the AppState-wide B1/B2 moves with Replace F/G, Replace H's
menu/responder/focus work and I's acceptance (`docs/editor-replace-gates.md` §7 rows F–I),
Find, and Export F/G's File commands and Print (`docs/export-gates.md:879-880`).

| PR | Scope | Expected gates | Security review |
|---|---|---|---|
| **A — this spec** | Two docs only; no checked box. | None | No |
| **B1 — types and forwarding** | Registry/root/window types and behavior-neutral forwarding façade; preserve all authority hooks, the 298 direct AppTests initializers, and existing APIs. No inventory logic change or new publish; still shared one-window behavior. | W0 inventory; W1 partition/hooks/regressions | **Yes**: authority/recovery storage moves |
| **L — window chrome** | Native `NavigationSplitView` sidebar, document column, Xcode-style inspector and toolbar (§10.1). Chrome plus `SidebarCommands` (27+) and `InspectorToggleCommands`; only the reviewed navigator focus parameter in `AppState+Workspace.swift`; no Find or export-banner file changes. Inspector user intent and width are scene state. | R17 launch stability; hosted suite unchanged | No |
| **B2 — registry enumeration** | Migrate all session consumers under I2, with explicit list extras and operation filters. Preserve one-window behavior; prove no missed direct reads by grep. | W1 enumerator/grep; W3 registry fixtures | **Yes**: ownership, pruning, fences |
| **C — independent state/routing, creation guarded** | Per-window state; deduplicated menus; remove singleton, retargeting every window-scoped `currentDocument` read that B2 left on the shared window to its operation's `WindowState` (I2); route hot key and all Find hooks, including Escape. Disallow native tabs until F. Close W0 bullet 2; disable or route **every** W0-bullet-1 path to the existing window, including system menus and onOpenURL scene creation. Any unavoidable second WindowState fails closed on **any** file/root open until D2. Hosted test fixtures may bypass only creation guards. | W0 external-open + creation-guard/close probes; W2/W3/W5 hosted bullets; W2 I2 `currentDocument` grep | **Yes**: cross-window authority |
| **D1-0 — decisions** | Record WD1, WD2, WD3, WD6's LRU half, WD7, and WD8 (§9.1), and split the old D1 row into D1a, D1b, and D1c. No code and no checked box. | None | No |
| **D1a — installed LRU capacity** | Add `installedURLs` to `WorkspaceSessionLRUPolicy` access and trim (W11 bullet 3, §7.1). Installed documents, derived from today's installation protection plus every connected window's shown session, do not count toward the limit of 8 and cannot be evicted. Other `protectedURLs` still count. A failed or fenced eviction still retains an over-limit cache (`agent.md` §5). `testZZZMemoryWithEightWarmSessionsAndTwoLiveWebViewsStaysUnderBudget` still passes. No user window creation; `WindowOpenAdmission` and disallowed tabbing stay as C left them. | W11 bullet 3 | **Yes**: eviction can drop session text |
| **D1b — root-scoped release** | Replace the global sweep in `clearClosedWorkspaceState`. Do not call `cancelWorkspaceSessionTasks(excluding:)`, the `removeEditorDocumentBindingRegistration` loop, `registry.removeAllWarmSessions()`, the reset to a new LRU policy, or the global `retainMetadataOnlyForRetiredEditorSessions` prune unchanged. The release set is the registry sessions whose retained authority or installed membership belongs to this root, minus any session any window still shows or installs. Preflight only that set: another root's fenced, quarantined, or conflicted session must not block this release, while the global transaction and store-load fences still do. Filter `firstUnretirableExternalConflict` to this root. Remove only that set's cache and LRU entries, preserving everyone else's recency, and prune metadata only for the retired sessions. Keep fences, bindings, proofs, quarantine, detached URLs, and pending external text and versions of every other session, including other roots and standalone warm sessions. Write the tests first and show each failing on `main`: one named hosted test per W3 bullet 7 item and per W6 bullet 5 item (including a window that shows a file from another root), plus W6 bullets 4 and 6. No user window creation; retain C guards. | W3 bullet 7; W6 bullets 4–6 | **Yes**: retirement and quarantine |
| **D1c — shared root context** | The registry keeps one `WorkspaceRootContext` per canonical root, reference-counted by windows (WD2 i; iv stays forbidden). Opening a root already open attaches to that context: one security-scope start, one watcher, and one scan per refresh. Each window still owns its whole filtered tree, Show All Files, expansion, selection, reload disposition, and search; only the scan snapshot and generation are shared. A watcher event or a mutation refresh reconciles every window on that root and refreshes each window's active search. Deferred refresh is per root: an R2 watcher event during an R1 namespace transaction stays queued and is serviced on drain, and drain services every queued root. The image-placement count stays per root under the app-wide transaction lock. The last release runs D1b's release; retained authority may keep the scope alive. §4.3 refusals happen before root installation and offer to show the other window (`KeyWindowRouter` focus): an ancestor or descendant root, and a root containing a standalone file installed in another window. Routing a single file inside an open root needs WD1 and WD7 and stays with D2, so that half of W6 bullet 8 stays open. Adopting a warm session into window 2 after window 1 switched away transfers the writer synchronously; window 1's stale installation cannot publish, and a delayed SwiftUI teardown cannot revoke the new writer. If `App/AppState+Workspace.swift` or another touched file would pass about 400 lines, the first commit is a mechanical split with no behavior change. A typing A/B in `docs/perf/` shows the fan-out adds no per-keystroke work. No user window creation, no `WindowOpenAdmission` change, and tabbing stays disallowed. | W6 bullets 1–3, 7, 8 (refusals only), and 9; W4 bullets 3–4 | **Yes**: mutation, shared scope, quarantine |
| **D2 — routing and window lifecycle** | WD1 focus policy, New Window, external-open routing, guarded opens and close lifecycle (WD3/WD7/WD8). Remove C fallback only after these paths pass. | W4; W7; W8 | **Yes**: ownership and close retention |
| **F — native tabs** | Enable tabbing; New Tab, titles, merge/move. W0 must prove New Tab joins the key group. | W0 tab identity/New Tab; W10 | No |
| **E — restoration** | After F: restoration/migration, missing-item handling, tab-group/order records and restoration. | W9 | **Yes (light)**: bookmarks |
| **G — residency/acceptance** | Preview residency, dual-window XCUITest, memory/typing measurements, accessibility; no bridge changes. | W11; W12; W13 | No |

Order: {L, B1} → B2 → C → D1-0 → D1a → D1b → D1c → D2 → F → E → G. D1-0 is docs only. D1a, D1b, and D1c replace the single D1 row and land in that order. E follows F because it restores tab order.
L lands before B1; its narrow navigator focus parameter must be preserved when B1 forwards activation. Both L and B1 must land before B2.
Implementation completion requires relevant package/hosted tests, `make format`, `make lint`,
`make test`, `make build`, and `git diff --check`; PR bodies name closed and open gates.

### 10.1 Window chrome (PR L)

PR L rebuilds the workspace window's chrome ahead of C so that C splits state under the
final layout instead of a layout that is about to move. It changes chrome and its menu commands, with a narrow navigator focus parameter.

```
┌──────────────┬──────────────────────────────────────┬──────────────┐
│ ● ● ●   [⊟]  │ post.md · blog       [▤|◫|✦]  [⊟]   │              │  toolbar: title + subtitle,
│ [🗂] [🔍]     │ 📁 blog › posts › 📄 post.md    MDX  │ Frontmatter  │  layout picker, inspector toggle
│ ▾ 📁 blog    │ ╭ ⚠ File changed on disk   [Reload] ╮│  title …     │  jump bar; glass notice cards
│    📄 a.md   │  editor            │ preview         │ File         │
│ (+) (⌯)      │ 188 lines · 432 words                │  name, type… │  status bar
└──────────────┴──────────────────────────────────────┴──────────────┘
   sidebar column           detail column               inspector
```

- **Shell.** On macOS 27+ `WorkspaceWindow` is a `NavigationSplitView` (sidebar ideal width
  256, range 220–320); macOS 14–26 keep the fixed-width (256) `HStack` shell with the system
  sidebar material, because macOS 15 still hits R17 in the split view (below). The detail column holds the document and, trailing it, `InspectorColumn`
  (default 280, drag-resizable 240–360). SwiftUI's `.inspector` is not used: with it
  mounted, even with static content, the editor's SwiftUI updates intermittently stalled in
  the hosted Find/Replace gates (decision log, PR L). On macOS 27 the system draws the
  sidebar and toolbar as Liquid Glass; custom surfaces use `plainsongGlass` (glass on
  macOS 26+, a material fallback before).
- **R17.** The detail content sits inside a `GeometryReader` so the split column's minimum
  size never follows the editor or web view. Without it the window re-entered Update
  Constraints until AppKit threw (20 of 20 restore launches); with it, 30 of 30 launches were
  clean on macOS 27. On the macOS 15 CI runner the split view still threw, from STTextView's
  layout requesting constraint updates, hence the version split (`docs/risk-register.md` R17).
- **Per-window chrome state.** Sidebar column visibility is view `@State`; inspector
  user intent and width are `@SceneStorage` (`plainsong.inspectorPresented`,
  `plainsong.inspectorWidth`), shown by default and hidden
  while no document is open. Neither lives in `AppState`, so C inherits per-window chrome
  without moving it. Toggle Sidebar (⌃⌘S) comes from `SidebarCommands` on macOS 27+ only. Show/Hide
  Inspector (⌃⌘I) is `InspectorToggleCommands`, which observes the app-global
  `InspectorMenuState`: each window's `InspectorVisibility` registers there while its window
  is key (become/resign-key notifications), so the command disables when no workspace window
  with a document is key and never falls back (§5.1). It reflects visible state after key, intent, document, and geometry changes. SwiftUI
  focused values are deliberately not used: any `focusedSceneValue` or `focusedSceneObject`
  on the workspace window delayed the editor's own updates in the hosted gates. C should
  fold `InspectorMenuState` into `KeyWindowRouter`.
- **Entry points.** The toolbar holds only the layout picker and the inspector toggle.
  Open and Save leave the toolbar; File › Open… ⌘O, Save ⌘S, and the empty-state Open… and
  recent items remain (§5.2).
- **Stable identifiers.** `plainsong.editor.fileName` (now the jump bar's document segment,
  same label; its value stays the file name, and the window's document-edited state announces Edited; its menu is a separate pop-up button laid over it), `plainsong.workspaceSearch.mode` (the navigator selector container,
  with Files and Search buttons), `plainsong.workspaceSearch.queryField` (still an owned
  `NSTextField`), `plainsong.editor.textView`, `plainsong.editorFind.*`, and the window
  identifier with its `exportHTMLWindowRegistered` post. The Search sidebar still unmounts in
  Files mode, the Find bar stays in the document column of the same `NSWindow`, and the
  sidebar stays left of x = 280 for the hosted Search activation test.
- **C builds on L.** C replaces `@EnvironmentObject AppState` in these views with the
  window's state; the view split (`WorkspaceDetail`, `DocumentJumpBar`, `WorkspaceToolbar`,
  `WorkspaceInspector`, `WorkspaceStatusBar`, `EmptyEditorState`) keeps those edits local.

## 11. Gates

Boxes start unchecked. Each bullet names the evidence it needs: a named hosted test, a
named XCUITest, a perf measurement recorded in `docs/perf/YYYY-MM-DD-<slug>.md`, or an owner smoke
recorded in the closing commit.

### W0 — Baseline inventory and mechanism probe

- [ ] Inventory second-window paths on the shipped build: tab-bar "+", Show Tab Bar, Merge All Windows, Finder Open With, Dock drop, and onOpenURL-created scenes. Include system-provided menu shortcuts in the ⇧⌘N/⌘T collision check. *Owner smoke.*
- [ ] Chosen external-open mechanism delivers every Finder/Dock open to exactly one existing window, with no blank scene. Close in **PR C**. *Hosted probe + owner smoke.*
- [ ] **PR C guard:** tabbing disallowed until F; every first-bullet creation path disabled/routed to the existing window. If a second WindowState still appears, every file/root open there refuses until D2. *Named hosted tests + owner smoke covering each path.*
- [ ] With SwiftUI owning the delegate, the chosen `windowShouldClose` interception safely vetoes/defers close without breaking scene teardown. Close before C ships. *Hosted probe + owner smoke.*
- [ ] WindowState identity survives tab merge/move and `openWindow`; command creation gives a fresh state, and New Tab ⌘T joins the key window's group. Close before F relies on it. *Hosted probe + owner smoke.*
- Evidence: B1 re-ran the §2.1 code inventory at its head. No `handlesExternalEvents`, `openWindow`, `tabbingMode`, `allowsAutomaticWindowTabbing`, `newWindowForTab`, focused-value, restoration, or `applicationShouldTerminateAfterLastWindowClosed` use exists outside PR L's `@SceneStorage`. `CommandGroup(replacing: .newItem)` still removes New Window. Bullet 1 still needs the owner smoke on a shipped build. Bullet 5 stays open until F.
- Evidence (C, hosted only): boxes above stay open because each one still needs owner smoke.
  - Bullet 2: `WindowFacadeRoutingAppTests/testExternalOpenReachesTheAdmittingFacade` routes `openExternalFile` from a refused sibling to the admitting façade. Finder, Dock, and `open -a` are not covered.
  - Bullet 3: `testAttachedWorkspaceWindowDisallowsTabbing` sets `tabbingMode` to `.disallowed` and the router sets `allowsAutomaticWindowTabbing` false. `testRefusedSiblingFailsClosedWithoutConsumingRestore` refuses `open`, `openWorkspace`, `openWorkspaceFile`, `newFile`, and launch restore on an unregistered sibling. Tab-bar "+", Show Tab Bar, Merge All Windows, and system menu shortcuts still need owner smoke.
  - Bullet 4: `WindowFacadeLifecycleAppTests/testCloseInterceptionVetoesAndDefersWithoutReplacingTheDelegate` sends real `performClose` calls. A veto and a one-time defer keep the window visible without asking the wrapped delegate. Then the close asks it, it sees `windowWillClose` once, and the window gets that delegate back. Other delegate messages (`windowDidResize`) still reach it. The interceptor holds the wrapped delegate strongly until the close, because `NSWindow` caches its selectors. Nothing in production sets the veto or defer flag yet: closing a dirty or quarantined window is W7. Owner smoke for this bullet checks only that a normal window closes and reopens.
  - Closing the only window and reopening it (Dock, Finder, `open -a`) gives the new scene the app-owned façade again, which keeps its document as the one `AppState` did before C: `WindowFacadeLifecycleAppTests/testClosingTheOwnersWindowLetsTheNextSceneReuseTheOwner`. A closed sibling leaves every registry inventory, the admission table, and the router: `testClosingASiblingWindowReleasesItEverywhere`.
  - Review follow-up: with no attached workspace window, File › New File, Open, and Open Recent call `openWindow(id:)` for the workspace group and run when the owner attaches (`testFileCommandWithNoWindowReopensTheOwnerAndRunsThere`). Only the latest file command runs; a Quit refusal stays beside it (`testQuitRefusalStaysQueuedBesideTheLatestFileCommand`). An open that never attaches is dropped, and the next command opens again (`testSilentSceneOpenExpiresSoTheNextCommandOpensAgain`, `testExpiredReopenDropsAStaleQuitRefusal`). A command that was waiting when launch produced no scene opens one (`testLaunchWithoutASceneOpensForACommandThatWasWaiting`). One workspace window still receives those commands when Settings is key, and comes forward (`testSingleWorkspaceWindowFileCommandComesForwardWhenSettingsIsKey`). A Quit refusal does the same (`testQuitRefusalWithNoWindowReopensTheOwnerBeforeShowingTheError`). `home` does not return a refused scene, and that scene closes with `close()` so a vetoing delegate cannot keep it (`testRefusedSceneClosesWithoutAskingAVetoingDelegate`). Dock, Finder, and `open -a` remain owner smoke. See `docs/decisions/2026-10-29-windows-no-window-file-commands.md`.
  - Owner smoke also checks New File, Open, and Open Recent after closing the only workspace window, and a refused Quit in that state. `testFileCommandBeforeTheFirstSceneWaitsForItsWindow`, `testFileCommandWithSeveralWindowsAndNoKeyWindowDoesNotGuess`, and `testQuitRefusalForAClosedSessionUsesAnAttachedHome` cover the launch queue, ambiguous routing, and an attached error target without claiming those native SwiftUI paths are smoke-tested.
  - Claimed-scene follow-up: `WindowFacadeReopenQueueAppTests/testLaunchWaitsForTheClaimedOwnersWindowToAttach` and `testFileCommandDuringDockReopenWaitsForTheClaimedOwner` hold attachment until after launch completion or a File command and verify that no extra scene is requested. `testClaimedOwnerCanRetryAfterItsAttachWaitExpires` covers the bounded wait, retry, and reset after attachment. `testExpiredClaimReopensOntoTheOwnerAndIgnoresTheOldScene` and `testLateRetiredSceneCannotReplaceTheAttachedOwner` release an unattached claim on expiry and reject the retired scene's window in either order. These are controlled lifecycle tests; native Dock/Finder owner smoke stays open. See `docs/decisions/2026-10-29-windows-claimed-scene-attach-wait.md`.

### W1 — Behavior-neutral partition (B1/B2)

- [x] Every AppState property follows §3.2; forwarding preserves all 16 `didSet { noteEditorReplaceAuthorityInputDidChange() }` hooks (`App/WindowState.swift:30`, `:67`, `:71`, `:78`; `App/AppDocumentRegistry.swift:67-166`). *PR checklist + named stale-plan hosted tests for each moved input.*
- [x] I2 grep gate (B2): `git grep -n -w -E 'currentDocument|sessionCache' -- App Packages` has no `sessionCache` reads outside the registry. No `currentDocument` hit outside `WindowState` builds or checks an inventory: each is classified window-scoped, and C retargets it (W2). Review every hit, including extensions and forwarding APIs; attach the command/output and classification in the PR. *Source audit.*
- [x] Registry enumeration covers all §2.3 consumers, including pruning, autosave/addressability, untitled ownership, and search. Register a session only in a second WindowState and prove each operation sees it with its documented filters/extras. *Named hosted tests.*
- [x] Existing package, AppTests, and PerformanceTests pass with mechanical renames only. *Exact-head CI run with named jobs/suites.*
- [x] No new keystroke publish; unchanged typing test within noise. *Perf measurement.*
- [x] AppState and new files meet SwiftLint's 1000-line error and ~400-line guidance. *`make lint` output + recorded source line counts.*
- Evidence (B1):
  - Bullet 1: the hooks are counted on `282a798`: 15 one-line `didSet` hooks plus `currentDocument`'s multi-line one. The `currentDocument`, `workspaceRootURL`, and `workspaceAccess` Export as HTML… context hooks and the `exportHTMLStatus` announcement are preserved too. `WindowStatePartitionAppTests` covers this. `testAppStateStoresOnlyItsContainers` and `testEachContainerHoldsExactlyItsSection32Inventory` pin §3.2 (121 properties). In `testEveryAuthorityInputRefusesAStalePlanThroughFacadeAndContainer`, each of the 16 inputs, through the façade and through its container, advances the generation and leaves a plan captured before it refused at commit (32 cases). It fails when the `detachedSessionURLs` hook is removed, and it requires that no write reaches `UnwiredContainerHook`. `testFacadeAndContainerShareStorage` and `testEditorFindHostSharesTheRegistryReplaceAuthority` also cover this, as do four export-context tests. `WindowStatePartitionWiringAppTests` checks that a container `AppState` never connected fails loudly. In `testUnwiredWindowStateReportsEachHookedInput`, `testUnwiredRegistryReportsEachAuthorityInput`, and `testUnwiredRootContextReportsItsExportInput`, every hooked input on a bare container reports once, naming its own line. `testAppStateConnectsEveryContainerHook` requires no report from an `AppState`'s containers.
  - Bullet 5: `docs/perf/2026-10-27-windows-b1-typing-ab.md`. Over 200 body edits, `AppState` sent one `objectWillChange` on both `main` and B1: the session's own `isDirty` flip. `WindowStatePartitionPublishAppTests/testBodyEditsPublishOnlyTheSessionsOwnChanges` keeps that. In six interleaved Debug pairs at load 17.6–22.9, the app-backed hosted typing medians were 7.63 / 7.93 / 6.95 ms on B1 against 8.64 / 7.71 / 7.73 ms on `main` (ordinary / pair / marked text). Paired differences changed sign, and every sample was under 16 ms.
  - Bullet 6: line counts at the B1 head: `App/AppState.swift` 366 (993 before), `App/WindowState.swift` 124, `App/WorkspaceRootContext.swift` 69, `App/AppDocumentRegistry.swift` 271, `App/UnwiredContainerHook.swift` 27, `App/AppState+WindowStateForwarding.swift` 153, `App/AppState+WorkspaceRootForwarding.swift` 88, `App/AppState+RegistryForwarding.swift` 210, `App/AppState+SessionRegistryForwarding.swift` 168, `App/AppStateSupportingTypes.swift` 261, `App/AppState+DocumentCommands.swift` 149. The new tests are 172, 275, 199, and 121 lines. `make lint` with the pinned SwiftFormat 0.62.1 reports "0/1043 files require formatting" and "0 serious". No suppression was added.
  - Bullet 2 (B1): stayed open for B2. B1 runs the command and classifies every hit in its PR. Consumers still read through the façade, which B2 migrates. The `-E '\b…\b'` form this bullet first gave matches nothing with macOS git 2.56: its POSIX ERE has no `\b`, so the gate would pass vacuously. Use `-w` or `-P`.
- Evidence (B2):
  - Bullet 3: every §2.3 consumer takes its sessions from `AppDocumentRegistry.sessions(from:)` or its window and warm-cache predicates (`App/AppDocumentRegistry+Sessions.swift`). `WindowStateRegistryAppTests` connects a second `WindowState` and shows it a session that no cache, retirement, binding, or recovery holds. Each test then hides that session again as a control. The fifteen named tests:
    - `testOwnershipInventoriesIncludeASessionOnlyASecondWindowShows`: mutation-managed, Save Copy, and termination inventories, LRU protection, and addressability.
    - `testAnUntitledDocumentInASecondWindowIsOwned`: untitled ownership.
    - `testAutosaveFlushSavesADirtySessionOnlyASecondWindowShows` and `testAutosaveOfAHiddenSessionIsRefused`.
    - `testAWindowPromptBlocksOnlyItsFilesSaveInEveryWindow`.
    - `testPruningKeepsStateForASessionOnlyASecondWindowShows`.
    - `testExternalConflictAndProofReleaseSeeASecondWindowsSession`.
    - `testSearchOverlaysIncludeASecondWindowsDirtySession`.
    - `testClosingTheWorkspaceKeepsStateForASecondWindowsSession`.
    - `testTerminationRefusesForASecondWindowsUnsavableSession`.
    - The W3 tests below.
  - Making the enumerator see only the first window fails 14 of the 15; the remaining one is itself a control.
  - Bullet 2: the B2 PR classifies the 176 hits at its head. All 12 `sessionCache` hits are in `AppDocumentRegistry` and its `+Sessions` extension. The 164 `currentDocument` hits are `WindowState` storage and its `shownSession` projection, the shared window's forwarder and construction, window-scoped reads in `AppState` extensions and views, and 2 hits in the bundled Mermaid build. None builds or checks an inventory; the last inventory-style uses moved to the enumerator. The owner chose this reading over moving the window-scoped logic onto `WindowState` in B2 (`docs/decisions/2026-10-27-windows-b2-registry-enumeration.md`). The zero-hit `currentDocument` form is W2's last bullet, for C.
  - Bullet 4: B1's exact-head CI run on `11f5ce8` passed the `packages`, `hosted (app)`, `hosted (ui-performance)`, `preview`, and `build-and-test` jobs (GitHub Actions run 40435132020). B2's only test edits are the mechanical `appState.sessionCache` → `appState.registry.sessionCache` rename and the inventory's new `registeredWindows` entry. Its own CI run re-checks this.

### W2 — Two windows never mirror each other's document

- [ ] Two production `WorkspaceWindow`s with separate `WindowState`s open `A.md` and `B.md`. Editor text, selection, editor/preview scroll, preview render, title, file header, Find visibility/query, search mode/results, banners, and layout are independent. Switching the document in window 1 leaves window 2 untouched. *Named hosted test.*
- [ ] The same holds for two different roots. *Named hosted test.*
- [ ] An external change to `A.md` shows its banner only in the window showing `A.md`. *Named hosted test.*
- [ ] The first bullet passes out of process (PR G). *Named XCUITest.*
- [x] I2 after C: `git grep -n -w currentDocument -- App Packages` has no hit outside `WindowState` (the bundled Mermaid build excepted). Every window-scoped read that B2 classified now goes through its operation's `WindowState`. *Source audit + PR classification.*
- Evidence (C), partial: `WindowFacadeRoutingAppTests/testTwoWindowsKeepIndependentDocumentsRootsAndExternalBanners` opens two temporary roots with `openWorkspace` on two admitted façades and activates `A.md` and `B.md` with `openWorkspaceFile`. Each façade has its own `WorkspaceRootContext`, security scope, and root authority, and each session's retained location is anchored in its own root. A dirty `A.md` is rewritten on disk, window 1's own FSEvents watcher delivers it, and only window 1 shows the prompt and loses Save. Layout, Find bar and query, and search query stay separate. Bullets 1–3 stay open: `WorkspaceWindow` is not mounted (SceneStorage needs the SwiftUI app lifecycle), so selection, editor and preview scroll, preview render, title, and file header are not observed, and the same file in two windows is WD1.
  - Bullet 5: `git grep -n -w currentDocument -- 'App/*.swift' 'Packages/*.swift'` at this head hits only `App/WindowState.swift` (the stored property and its `shownSession` projection). No `AppState` forwarder or view still says `currentDocument`.

### W3 — Ownership refusals are cross-window

- [x] Save Copy from window 1 onto the file current in window 2 is refused, including a hard link and a case alias. *Named hosted test.*
- [x] An export destination owned by window 2 is refused (`validateExportArtifactDestinationOwnership`, through both its Save Copy and mutation inventories). *Named hosted test.*
- [x] A mutation destination owned by a window-2 session is refused (`validateWorkspaceMutationDestinationOwnership`). *Named hosted test.*
- [x] The retained-authority collision and physical-duplicate checks see window-2 sessions. *Named hosted test.*
- [x] Termination refuses for a blocked background-window session and focuses it; an unseen warm blocked session presents its error/prompt in the home/frontmost workspace window. *Named hosted tests.*
- [x] A recovery-store load failure fences every window; the recovery banner has the §3.2 home window. Write/trash notices and unseen-session autosave failures retain their home/session routing across close. *Named hosted tests.*
- [ ] Closing R1 never prunes pendingExternalTexts/versions, bindings, proofs, detached URLs, or quarantine for a session window 2 shows. Closing R1 also must not remove that session's editor binding registration, cancel its background autosave or statistics tasks, or drop its warm-cache entry. `clearClosedWorkspaceState` currently does all three for every closed session that is not retired: `cancelWorkspaceSessionTasks(excluding:)` (`App/AppState+WorkspaceRetirement.swift:229`), `removeEditorDocumentBindingRegistration(for:)` (`:230-234`), and `registry.removeAllWarmSessions()` (`:235`). *Named hosted tests (D1b), one per item.*
- [x] A prompt shown in window 2 blocks that file's Save/autosave from any window or background task; window 1's prompt cannot block an unrelated file. *Named hosted tests.*
- Evidence (B2): "Window 2" is a second, connected `WindowState`, a registry fixture. User window creation stays guarded until C. The tests below are in `WindowStateRegistryAppTests`, and each hides window 2's session as a control.
  - Bullet 1: `testSaveCopyOntoASecondWindowsFileIsRefused` covers the file itself, a hard link, and a case alias on a case-insensitive volume. The alias is skipped on a case-sensitive one. Once window 2 stops showing the file, the hard link is writable.
  - Bullet 2: `testExportOntoASecondWindowsFileIsRefused`. The Save Copy walk refuses a hard link, and the mutation inventory refuses the file's own path.
  - Bullet 3: `testMutationDestinationOwnedByASecondWindowsSessionIsRefused`.
  - Bullet 4: `testRetainedAuthorityCollisionAndPhysicalDuplicateSeeASecondWindowsSession`.
  - Bullet 8: `testAWindowPromptBlocksOnlyItsFilesSaveInEveryWindow`, through `isSaveBlockedByWindowPrompt(at:)` (§3.4 I3).
  - Open:
    - Bullet 5: `WindowStateRegistryAppTests/testTerminationRefusesForASecondWindowsUnsavableSession` refuses termination, leaves the error on window 2's `WindowState`, and records that window as `KeyWindowRouter.focusedWindowState`. `WindowFacadeRoutingAppTests/testRecoveryBannerAndUnseenFailureStayOnTheHomeWindow` presents an unseen session's error on the home façade.
    - Bullet 6: the same test keeps `workspaceMutationRecoveryBannerPlacement` at `.global` on the home façade and `.hidden` on the sibling while the load-failure flag is set. `testClosingAFacadeRetargetsItsNotice` moves a write notice to the surviving façade after the owner façade closes. Unseen autosave failures use `present(_:title:for:)`, which is the path the recovery test calls.
    - Bullet 7: closing keeps window 2's proofs, pending external text, and detached URL, and a quarantined write refuses the close (`testClosingTheWorkspaceKeepsStateForASecondWindowsSession`). Closure still removes every closed session's editor binding registration, and root-scoped release is D1b. B2's security review found that closure also cancels those sessions' background tasks and drops their warm-cache entries, and the bullet now names all three for D1b.
  - D2 must decide one consequence. The Save Copy walk fails closed on a candidate with no ownership record, so an untitled, record-less document in another window refuses every Save Copy and export (`testAnUntitledRecordlessDocumentInASecondWindowFailsSaveCopyClosed`).

### W4 — One writer per file across windows

- [ ] Every §5.2 entry point that targets a file current in another window focuses that window and creates no second installation. *Named hosted tests, one per entry point.*
- [ ] Hard links and case or NFC/NFD aliases count as the same file. *Named hosted test.*
- [ ] Every session has ≤ 1 writer always and ≤ 1 live installation after SwiftUI teardown settles. Adoption revokes the old writer synchronously; late teardown cannot revoke the new writer. *Debug assertions + named hosted test with delayed teardown.*
- [ ] A warm session adopted by window 2 after window 1 switched away transfers the writer; window 1's stale installation cannot publish. *Named hosted test.*
- Evidence: _open_

### PR C scheduling re-verification (R22)

Before accepting C, keep the inspector mounted and run
`EditorFindHostedGateTests/testHostedReplaceInvalidDelimiterStaysRawWithoutMarkdownRepair`
and `EditorFindHostedGateTests/testHostedKeepMineInWYSIWYGRetainsFoldsImageMarkersAndFindDecorationWithoutAnEdit`
16 times each. Retain all attempts; the `.inspector` / focused-values / grouped-Form
scheduling root cause remains unknown. This is an additional gate, not closure by a green rerun.

### W5 — Menu commands act only on the key window

- [x] With window 2 key, Format, Find (⌘F, ⌘G, ⇧⌘G, ⌘E), the installed Replace dispatcher, Save, ⇧⌘P, Toggle Workspace Search (menu and Carbon), and New File act on window 2. Window 1's source, selection, undo stack, and Find query are unchanged. *Named hosted tests with a designated key window. Replace menu/UI coverage follows Replace H; Export/Print coverage follows Export F/G.*
- [x] With Settings key and a workspace window main, document commands are disabled and ⌘B does not reach the main window's editor. *Named hosted test.*
- [x] Menu enablement follows the key window within one run-loop pass. Background-window UI publishes do not republish it; registry/recents changes update relevant deduplicated facts. *Named hosted test with a publish counter.*
- [x] Background save completion re-enables Save for the active file; registry fence/quarantine transitions and recents also update enablement without unrelated menu churn. *Named hosted test with a publish counter.*
- [x] Every Find hook, including Escape cancelFind, reaches its originating text view's window. *Named hosted tests.*
- [x] A preferences change updates every window through one shared callback. *Named hosted test.*
- Evidence (C):
  - Bullet 1: `testMenuTargetIgnoresAForeignKeyWindowAndHonorsTheKeyFacade` designates window 2 with `testingKeyWindow`. `PlainsongWorkspaceSearchKeyAction.performIfAvailable()` toggles search on window 2 only, and `showOrRefocusEditorFind()` opens window 2's bar and leaves window 1's closed. Format still goes through the responder chain; `MarkdownSTTextView.plainsongPerform` returns when its window is not key and some other window is. Save, New File, ⇧⌘P, and the Replace dispatcher were not each executed in this probe. Replace menu coverage stays with Replace H.
  - Bullet 2: the same test points the key-window override at a window with no façade. `menuTarget` is nil, and a fresh `MenuBarState` snapshot has `hasActiveWorkspaceWindow`, `hasOpenDocument`, and `canSave` false. ⌘B is the Format responder path above; this probe does not send ⌘B into a text view.
  - Bullet 3: `testBackgroundFacadePublishDoesNotRepublishTheMenu` counts `MenuBarState.$snapshot`. A background façade's search query publishes nothing. Changing `recentItemURLs` on the pinned façade updates the snapshot.
  - Bullet 4: `testBackgroundSaveAndRegistryFencesUpdateSaveWithoutMenuChurn` pins the key façade, counts `MenuBarState.$snapshot`, and checks three registry inputs. A write fence, quarantine (`indeterminateWorkspaceMutationSessions`), and `workspaceMutationOperationRecoveryLoadFailed` each disable Save and re-enable it when cleared. Recents update the same snapshot. Search typing on the other façade adds no publish. Setting `isSaving` disables Save; clearing it and `noteMenuEnablementDidChange()` (what `save(session:)` does after the write) enables it again. The home façade then saves the key window's dirty file; Save stays enabled.
  - Bullet 5: `testFindCancelReachesTheOriginatingWindow` installs the hooks, opens both bars, and Escape-cancels through the second window. Only that bar closes. `showFind`, `findNext`, `findPrevious`, and `useSelectionForFind` take the same `NSWindow?` and resolve it with `KeyWindowRouter.facade(for:)`.
  - Bullet 6: `testPreferencesFanOutReachesEveryFacade` observes `objectWillChange` on both façades. One `preferences.setDefaultFolderURL` notifies both. The callback is installed once on the shared registry.

### W6 — Same-workspace shared root context

- [ ] Two windows on one root share one watcher, one security-scope start, and one scan per refresh. *Named hosted test.*
- [ ] A rename in window 1 of the file current in window 2 relocates window 2's session. Window 2's saves are refused during the fence. Both trees update with each window preserving its own Show All Files filter, expansion, selection, and reload disposition. *Named hosted test.*
- [ ] Closing window 1 keeps its root alive. Last release checks only eligible R1 sessions once; any still-installed session/authority survives. *Named hosted test.*
- [ ] Last R1 release preserves R2 warm sessions and standalone warm sessions, their tasks/metadata and LRU entries/recency; no global LRU reset or prune. *Named hosted test.*
- [ ] Last R1 release leaves every session another window shows registered and warm: its editor binding registration, its background autosave and statistics tasks, and its warm-cache entry all survive. The same holds when that window shows a file from another root. `clearClosedWorkspaceState` currently does all three for every closed session that is not retired: `cancelWorkspaceSessionTasks(excluding:)` (`App/AppState+WorkspaceRetirement.swift:229`), `removeEditorDocumentBindingRegistration(for:)` (`:230-234`), and `registry.removeAllWarmSessions()` (`:235`). *Named hosted tests, one per item.*
- [ ] R2 fenced/quarantined/conflicted state does not block an otherwise-safe R1 release and is unchanged by it. Global transaction/store-load fences remain enforced. *Named hosted tests.*
- [ ] An R2 watcher event during R1 mutation stays queued and refreshes R2 after drain; every deferred root is serviced. *Named hosted test.*
- [ ] Overlapping roots and a root containing an installed standalone file refuse before installation; files inside an open root route per §4.3. *Named hosted tests.*
- [ ] A second namespace transaction, from any window or root, is refused while one runs. *Named hosted test.*
- Evidence: _open_

### W7 — Window close lifecycle

- [ ] A dirty, savable document is saved; it stays warm unless eligible for last-root retirement. *Named hosted tests.*
- [ ] Every transient/quarantine state in §6.2 refuses/defers close without loss. Stable blocked sessions close only with registry retention proof; prompts, text, authority, and protection survive adoption into another window. Last-root release obeys the same rule. *Named hosted tests.*
- [ ] Closing the last window leaves the app running. *Owner smoke.*
- [ ] The installation is revoked, the writer released, and the LRU reconciled; a failed eviction candidate is still retained (§5). *Named hosted test.*
- [ ] The preview controller is invalidated and released (its weak reference becomes `nil`). *Named hosted test.*
- [ ] A user close removes the restoration record; a quit does not. *Named hosted test.*
- Evidence: _open_

### W8 — External-open and ⌘N routing

- [ ] Every §5.2 row: focus the existing owner, reuse its specified empty target, or open a new window; external events before activation resolve frontmost workspace z-order. Exactly one window acts and none is left blank. *Named hosted tests + owner smoke for Finder and Dock.*
- [ ] ⌘N creates a file in the key window's root. ⇧⌘N opens an empty window that does not restore. *Named hosted test.*
- Evidence: _open_

### W9 — Restoration

- [ ] Exactly one window per record, with the system "Close windows when quitting" setting on and off. *Owner smoke on an owner-provisioned logged-in macOS 14 VM (14.x/build recorded) and the current-macOS Mac (version/build recorded); W9 stays open until both environments exist and pass.*
- [ ] A mix of workspace and single-file windows restores each root or file, current document, layout, and tab order. *Named hosted test + owner smoke.*
- [ ] A missing or unresolvable bookmark is skipped with one notice, no empty window, and no panel. *Named hosted test.*
- [ ] With recovery pending, nothing else is restored. *Named hosted test.*
- [ ] The legacy single bookmark migrates to one record. *Named hosted test.*
- [ ] Records that break WD1 or WD2 collapse to the first. *Named hosted test.*
- Evidence: _open_

### W10 — Native tabs

- [ ] New Tab ⌘T joins the key window's group, and every W2 bullet holds between tabs. *Named hosted test + owner smoke.*
- [ ] Merge All Windows, Move Tab to New Window, and dragging a tab keep each tab's document, selection, undo stack, and Find state. *Owner smoke.*
- [ ] Tab titles are unique per §8, and closing a tab follows §6.2. *Named hosted test.*
- [ ] A background tab's preview follows §7.2 residency. *Named hosted test.*
- Evidence: _open_

### W11 — Memory

- [ ] The §7.3 configuration stays under 400 MB host RSS. Helper RSS and the per-preview host delta are recorded. *Perf measurement in `docs/perf/YYYY-MM-DD-<slug>.md`.*
- [ ] Hidden previews beyond two are torn down after the grace period (controller released), and visible previews are never torn down. *Named hosted test.*
- [ ] Separate installedURLs allows 8 warm sessions plus installed ones; other protectedURLs still count and failed/fenced evictions retain the over-limit cache. `testZZZMemoryWithEightWarmSessionsAndTwoLiveWebViewsStaysUnderBudget` still passes. *Named policy/hosted/perf tests.*
- Evidence: _open_

### W12 — Typing latency

- [ ] The §12 typing test with four windows open (two previews visible) stays under 16 ms. Three Debug and three Release runs are recorded. *Perf measurement.*
- [ ] Zero body evaluations or `objectWillChange` sends in other windows per keystroke. *Named test with an instrumented counter.*
- Evidence: _open_

### W13 — Accessibility and out-of-process acceptance

- [ ] Two windows opened with New Window, real key activation, menus act on the frontmost window, and every selector is scoped to a window. *Named XCUITest.*
- [ ] VoiceOver reads distinct window titles, and Full Keyboard Access reaches each window's Find chrome. *Owner smoke.*
- [ ] The existing UI tests use window-scoped queries and still pass. *Named XCUITests.*
- [ ] Zhuyin and Pinyin composition in window 2 while window 1 holds marked text corrupts neither (`agent.md` §13). *Owner smoke.*
- Evidence: _open_

## 12. Risks and `agent.md` edits for implementation

### 12.1 Risks

| Risk | Mitigation |
|---|---|
| Scene creation, restoration, tab merge, New Tab grouping, or close interception differs by macOS version. | W0/W9 mechanism evidence before reliance; C creation guards fail closed. |
| B1/B2 overlap Replace/Find and Export command streams. | Coordinate §10 surfaces; separate forwarding from enumeration/security review. |
| Missed cross-window owner or overbroad retirement/pruning. | I2 grep audit and W3/W6 root-scope fixtures; security review B1–D2. |
| Global fence clear or a single-root refresh drain loses protection/events. | I4 single transaction, root-specific queued refresh, W6. |
| Memory/typing grows with windows; hosted activation is artificial. | W11/W12 budgets and counters, R16 helper diagnostics, W13 real activation. |
| Overlapping roots break watcher and fence coverage. | Refuse under §4.3. |

### 12.2 `agent.md` edits the implementation PRs must make

| Section | Edit | PR |
|---|---|---|
| §3 | The `AppState.swift` layout comment ("open workspaces, recent items") describes the registry, root-context, and window-state split. | B1, B2 |
| §4 | Key types gain `WindowState`, `AppDocumentRegistry`, `WorkspaceRootContext`, and `KeyWindowRouter`. Data-flow item 6 ("on window resign") becomes one app-global flush. | B1, B2, C |
| §5 | Replace the "Multiple workspace windows … mirror" bullet with WD1, WD2, and §4.3. State that the LRU is global (8 warm + installed). Add close and quit rules and per-window restoration. The PR that changes the behavior makes the edit: D1a the LRU, D1b scoped release, D1c the shared root. | D1a, D1b, D1c, D2, E |
| §5 | Replace the "Tabs … deferred" bullet with native tabs per WD4. | F |
| §6.4 | Add New Window ⇧⌘N and New Tab ⌘T. State that every menu command acts on the key window and never falls back to the main window. | C, D2, F |
| §12 | Restate the memory row (§7.3). Measure typing with several windows open. | G |
| §14 | Move "window tabs" out of Phase 3 candidates. | F |
| §16 | UI tests use window-scoped selectors and include a dual-window smoke. | G |
