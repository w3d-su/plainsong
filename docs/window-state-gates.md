# Window-Scoped State and Native Window Tabs — Gate Specification

> **Status: spec only (Windows PR A, `phase3-window-state-spec`). No W-gate is checked.**
> This file changes no behavior, code, test, dependency, or `project.yml`. It does not
> edit `agent.md` because in-flight PRs touch it; §12.2 lists the `agent.md` edits the
> implementation PRs must make. The owner decisions in §9 have deadlines tied to the PR
> that first depends on them. Check a gate only with named-test or owner-recorded evidence
> in the same implementation commit.

Created 2026-10-01. Code citations are `path:line` on `origin/main` at `e95ac36` (#132,
Export PR E2, which moved export's ownership check to leaf-path inspection while keeping
the Save Copy and mutation inventories). References: `agent.md` §4, §5, §6.4, §12, §13,
§16, §17; the 2026-06-15 Decision Log row "Defer independent multi-window document state"
(`docs/decision-log.md:32`); `docs/editor-find-gates.md` F7 (dual-window note at
`docs/editor-find-gates.md:776-781`); `docs/editor-replace-gates.md` §5.1 (key-window-only
delivery); `docs/export-gates.md` D5 (ownership inventory).

## 1. Problem, goals, and non-goals

`PlainsongApp` creates one `AppState` and injects it into every `WindowGroup` window
(`App/PlainsongApp.swift:26`, `App/PlainsongApp.swift:42-44`). `AppState` calls itself the
state "for the current editor window" (`App/AppState.swift:133`) but holds one current
document, one workspace root, one find bar, one search sidebar, and one LRU. A second
window therefore mirrors the first (`agent.md` §5). The File menu removes New Window
(`App/PlainsongCommands.swift:21`), but other paths can still create a second window
(§2.1, W0).

| ID | Goal |
|---|---|
| G1 | Each window owns: its workspace root or single file, its current document, editor selection and scroll, its preview, its sidebar (expansion, selection, Show All Files, Files/Search mode, search query and results), its Find/Replace bar, its banners and prompts, its layout mode, and its error alerts. |
| G2 | Windows that share a file or a root never weaken an invariant in §3.4. |
| G3 | Menus, shortcuts, and the ⇧⌘F hot key act only on the key window. |
| G4 | Each window's workspace or file and current document are restored on relaunch. |
| G5 | Native macOS window tabs, where each tab is a window. |
| G6 | §12 typing latency does not change. The memory budget is restated for N windows and met. |

**Non-goals:** collaboration, multi-user editing, or sync; more than one host process
(WebKit helpers stay as they are today); iPad; any change to editing behavior inside a
window (editing behaviors, Find/Replace semantics, the preview pipeline, WYSIWYG gates);
a custom (non-AppKit) tab bar; split panes inside one window; one `DocumentSession`
installed in two editors at once (§4.1 option b); and bridge changes (`PROTOCOL_VERSION`
stays unchanged).

## 2. Baseline (code verified)

### 2.1 App shell and process-wide entry points

| Observation | Evidence | Consequence |
|---|---|---|
| One `@StateObject AppState` for the app. `MenuBarState(appState:)` is built from it. | `App/PlainsongApp.swift:26`, `:29`, `:31-34` | No window identity exists anywhere in the shell. |
| `WindowGroup { WorkspaceWindow().environmentObject(appState) }` | `App/PlainsongApp.swift:42-45` | Every window renders the same state. |
| Each window's `onAppear` reassigns `appDelegate.appState` and `PlainsongAppServices.appState`. | `App/PlainsongApp.swift:46-50` | The last window to appear wins. |
| `onOpenURL` calls `appState.openExternalFile`. | `App/PlainsongApp.swift:51-53` | Apple's `handlesExternalEvents(preferring:allowing:)` documentation says that when no open scene prefers or allows an event, or the modifier is omitted, SwiftUI creates a new scene. Plainsong declares no such modifier, so a Finder Open With or Dock drop while the app runs is expected to create a second, mirrored window. Unverified on this build (W0). |
| Each window's content flushes autosave on `willTerminate`. The app also flushes on any non-active `scenePhase`. | `App/PlainsongApp.swift:54-56`, `:62-65` | N windows mean N flushes at quit. |
| `PlainsongCommands(appState:menuBarState:)` captures the one `AppState`. | `App/PlainsongApp.swift:59-61`, `App/PlainsongCommands.swift:13` | Menu actions have no target window. |
| The `Settings` scene receives the same `AppState`; its panes read `appState.preferences`. | `App/PlainsongApp.swift:67-71`, `App/Views/SettingsView.swift:10-25` | Preferences are app-global. |
| `PlainsongAppServices.appState` is a weak static. | `App/PlainsongAppServices.swift:7-10` | A process-wide singleton. |
| The Carbon ⇧⌘F hot key registers while the app is active. Its action reads `PlainsongAppServices.appState`. | `App/PlainsongApplication.swift:57-75`, `:103-108`, `:142-150` | It toggles search in "the" state, not the key window's. |
| The delegate republishes `appState` and runs the Debug fixture entry points from its `didSet`. Termination asks that one state. | `App/PlainsongApplicationDelegate.swift:13-20`, `:42-54`, `:56-95` | Termination checks cover one state only. |
| The Find hooks are static closures that call `PlainsongAppServices`. The editor selectors call them with no window argument. | `App/EditorFindCommandDelivery.swift:17-33`, `Packages/EditorKit/Sources/EditorKit/EditorFindActionHooks.swift:6-14`, `Packages/EditorKit/Sources/EditorKit/EditorFindSpike.swift:68-83` | A responder-chain Find command cannot name its window. |
| The Find menu falls back to `PlainsongAppServices`. | `App/EditorFindCommandDelivery.swift:36-48` | Same. |
| Format and Find dispatch with `sendAction(_:to: nil, from: nil)`. | `Packages/EditorKit/Sources/EditorKit/EditingBehaviorsSupport.swift:60-62`, `Packages/EditorKit/Sources/EditorKit/EditorFindCommandDispatcher.swift:27-38` | AppKit falls back from the key window to the main window. This is safe only while menu enablement excludes non-workspace key windows (§5.1). |
| `MenuBarState` observes one `AppState` and republishes a deduplicated five-fact snapshot. | `App/MenuBarState.swift:9-24`, `:26-34`, `:41-53` | §5.1 keeps this contract and retargets it. |
| `CommandGroup(replacing: .newItem)` holds New File ⌘N, Open… ⌘O, and Open Recent. | `App/PlainsongCommands.swift:21-45` | There is no New Window command (§5.3). |
| View menu: layout cycle ⇧⌘P and Toggle Workspace Search ⇧⌘F. | `App/PlainsongCommands.swift:91-105` | Both must target the key window. |
| `git grep` finds no `handlesExternalEvents`, `openWindow`, `tabbingMode`, `allowsAutomaticWindowTabbing`, `newWindowForTab`, `SceneStorage`, `FocusedValue`, restoration API, or `applicationShouldTerminateAfterLastWindowClosed` outside `agent.md`. | repository search | AppKit and SwiftUI defaults apply. Whether the tab-bar "+" button or Window › Merge All Windows can create mirrored windows today is unverified (W0). |

### 2.2 Precedent: state already keyed by window

| Precedent | Evidence | Reuse |
|---|---|---|
| Find chrome focus is stored per window number, with a seam that stubs only which window is key. | `App/EditorFindHost.swift:37-51`, `App/AppState+EditorFindChromeFocus.swift:18-25`, `:34-40` | It becomes a per-window scalar. The seam pattern carries forward. |
| Find focus and select-all receipts are App-owned because `AppState` is shared. | `App/EditorFindUIState.swift:18-32`, `:148-159` | Keep the receipts per window. They still stop a remounted bar from replaying a token. |
| Responder probes are window-scoped. | `App/EditorFindResponderSupport.swift:41-44`, `:61-67`, `:76-87` | Reuse unchanged. |
| Replace advances its authority generation on every window's key change (`object: nil`). | `App/AppState+EditorReplaceAuthority.swift:36-43`, `:47-66` | Keep one app-global generation (§3.2). |
| The Replace dispatcher reaches only the key window's editor and never falls through to the main window. | `Packages/EditorKit/Sources/EditorKit/EditorReplaceCommandDispatcher.swift:64-70`, `:111-124` | The model for every document command. |
| `WindowKeyStateTracker` observes key changes of its own window only. | `App/Views/WindowKeyStateTracker.swift:13-28`, `:43-60` | The base for a window-to-state registry. |
| Workspace Search re-reads key status live and has a key epoch. | `App/AppState+WorkspaceSearchUI.swift:105-117` | Reuse. |
| Hosted tests designate the key window. | `AppTests/EditorFindHostedFocusGateTestSupport.swift:22`, `Packages/EditorKit/Sources/EditorKit/EditorSelectionProbe.swift:113-124` | The test pattern for W2–W5. |
| Retired workspace authority is already reference-counted by dependent sessions. | `App/AppState.swift:855-930` | The precedent for a reference-counted root security scope. |

### 2.3 Document and session ownership

| Area | Evidence | Today |
|---|---|---|
| `DocumentSession` does not publish `text` or `version`. It supports several text-change subscribers. | `Packages/MarkdownCore/Sources/MarkdownCore/DocumentSession.swift:34-41`, `:90-105` | Two previews can observe one session. Keystrokes do not publish. |
| One binding ID per session; many installations; one writer per session. Publication requires the writer. | `App/AppState+EditorBinding.swift:8-20`, `:116-129`, `:338-350`, `:444-450` | WS3B one-writer authority already spans every installation, in any window. |
| A non-writer installation converges only at its next writer activation (`.synchronize`). | `App/AppState+EditorBinding.swift:433-441` | There is no live cross-view propagation. |
| Reload and Keep Mine synchronize every live installation before finalizing. | `App/AppState+ExternalChanges.swift:147-160` | Already multi-installation. |
| Undo is per text view. | `Packages/EditorKit/Package.swift:12` pins STTextView 2.3.10. That version's initializer gives each view its own `CoalescingUndoManager`, and `STTextView+Undo.swift` returns it unless a delegate supplies one (dependency source, not in this repository). No `undoManager(for:)` exists in `Packages`. | Two editors on one session would hold two undo stacks. |
| One LRU, limit 8. Protected URLs still count toward the limit. Every editor installation is protected. | `App/AppState.swift:287-289`, `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceSessionLRUPolicy.swift:28-31`, `:94-100`, `App/AppState+WorkspaceSessions.swift:391-410`, `:416-451` | With N windows, only 8 − N warm slots remain (§7.1). |
| Autosave: a foreground task bound to `currentDocument`, background tasks per session, a flush over all sessions. | `App/AppState+Autosave.swift:6-25`, `:27-48`, `:68-97`, `:135-156` | The foreground/background split assumes one current document. |
| Every `WorkspaceWindow` flushes when **any** window resigns key (no `object:` filter). | `App/Views/WorkspaceWindow.swift:83-85` | N windows mean N flushes per resign. |
| The external-change and missing-file prompts are single values for the current document. Switching clears them. | `App/AppState.swift:178-184`, `App/AppState+ExternalChanges.swift:42-55`, `App/AppState+Workspace.swift:469-472` | They are per-window projections of per-file state. |
| Indeterminate-write quarantine is per session and blocks `canSave`. | `App/AppState.swift:321-326`, `:809-825` | Per file. |
| A namespace mutation sets depth 1, fences its sessions, and its end clears **all** fences. | `App/AppState+WorkspaceMutationTransaction.swift:24-48`, `:55-60` | Two concurrent root transactions would clear each other's fences (§3.4 I4). |
| The recovery stores load once, in `init`, from one Application Support directory. A load failure fences file access. Restore is skipped while recovery is pending. | `App/AppState.swift:416-450`, `:552-562`, `App/WorkspaceMutationOperationRecoveryStore.swift:786-805`, `App/AppState+WorkspaceMutationRecoveryLoadFailure.swift:5-13`, `:39-51` | Two loaders would read and rewrite the same durable files. |
| "Destination ownership is App-global". | `App/AppState+WorkspaceMutationPreflight.swift:116-118` | The rule this spec keeps. |
| Export checks a leaf-path destination against the Save Copy owner walk and the mutation inventory (`workspaceMutationManagedSessions()` plus owned state URLs). | `App/AppState+MissingFile.swift:374-481`, `App/AppState+ExportDestinationOwnership.swift:37-97` | Export inherits both inventories, so it spans windows once they do. |
| Export's app-private staging root comes from the process environment and home directory. | `App/AppState+ExportAppPrivateRoot.swift:9-26` | App-global, with no window coupling. |
| Eight hand-built session lists each read one `AppState`: autosave flush, retained-authority collision, physical duplicate, LRU protection, workspace closure, Save Copy candidates, mutation-managed sessions, termination sessions. | `App/AppState+Autosave.swift:7-11`, `App/AppState+WorkspaceSessions.swift:248-255`, `:313-319`, `:431-437`, `App/AppState+WorkspaceRetirement.swift:92-100`, `App/AppState+MissingFile.swift:483-490`, `App/AppState+WorkspaceMutationPreflight.swift:22-31`, `App/AppState+WorkspaceMutationTextRecovery.swift:442-450` | Each must span every window (§3.4 I2). |
| Hard links and case aliases are detected by physical identity. | `App/AppState+WorkspaceSessions.swift:309-336` | The basis for "same file" (§4.1). |
| Opening a workspace closes the previous one, starts one security scope, and starts one watcher. | `App/AppState+Workspace.swift:327-368` | Per root. |
| Opening a single file closes the workspace. | `App/AppState+Workspace.swift:271-273` | Must become "this window's root". |
| Closing or replacing a workspace retires its sessions, empties `sessionCache`, and resets the LRU. | `App/AppState+WorkspaceRetirement.swift:16-87`, `:243`, `:254` | Run as-is, it would tear down sessions shown in other windows. |
| A watcher event inspects only sessions of that root authority. An unanchored session records membership in at most one installed root. | `App/AppState+Workspace.swift:111-131`, `App/AppState+SessionOwnership.swift:491-538` (early return at `:496`) | Overlapping roots are unsafe (§4.3). |
| `WorkspaceFileTree` bundles the scanned root with `expandedNodeIDs` and `selectedNodeID`. | `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceFileTree.swift:149-160` | The tree must split into a shared root and per-window projections. |
| One last-opened bookmark key and ten recents. Restore runs once per `AppState` and re-saves stale bookmarks. A restored workspace selects its first file, not the last document. | `Packages/WorkspaceKit/Sources/WorkspaceKit/LastOpenedFileStore.swift:4`, `:25-43`, `Packages/WorkspaceKit/Sources/WorkspaceKit/RecentItemStore.swift:4`, `:12-20`, `App/AppState.swift:545-573`, `App/AppState+Workspace.swift:363-367` | Per-window restoration needs a list (§6.4). |
| Restoration starts from every window's `.task`, guarded only per `AppState`. | `App/Views/WorkspaceWindow.swift:79-82`, `App/AppState.swift:546-547` | Per-window state would restore into every new window. |
| Workspace Search requires a root. Its UI, task, and generation live on `AppState`. | `App/AppState+WorkspaceSearchUI.swift:8-10`, `:53-60`, `App/AppState.swift:163-171`, `:231-234` | Per window, bound to a per-root generation. |
| One cached `PlainsongPreferences` per `AppState`, with one `onChange` callback. | `App/AppState.swift:427`, `:451-453`, `App/PlainsongPreferences.swift:63`, `:67` | Two instances would not see each other's changes. |
| The layout mode persists under one key. | `App/AppState.swift:734-736`, `:770` | WD9. |
| `App/AppState.swift` is 978 lines. SwiftLint's default `file_length` error is 1000, and `.swiftlint.yml` does not override it. | `wc -l` | PR B must shrink it, not grow it. |

### 2.4 Packages

| Package | Single-window assumption | Evidence |
|---|---|---|
| WorkspaceKit | None. The LRU policy is a value type. The clone-source registry is process-wide but lock-protected. | `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceSessionLRUPolicy.swift:18`, `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceItemCreationTypes.swift:24-28` |
| PreviewKit | None. Each controller owns its WKWebView, `asset://` handler, render-ID counter, and `invalidate()`. But a controller (and its WKWebView) is created for every window that shows a document, even in source-only layout. | `Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift:27`, `:42-67`, `:153-170`, `App/Views/WorkspaceWindow.swift:102` |
| EditorKit | The Find hooks are static and carry no window. The thumbnail refresh proxy fans out by workspace-relative path, so it belongs to one root. Command routes are keyed per text view, which is safe. | `Packages/EditorKit/Sources/EditorKit/EditorFindActionHooks.swift:6-14`, `Packages/EditorKit/Sources/EditorKit/EditorImageThumbnailLoading.swift:82-85`, `Packages/EditorKit/Sources/EditorKit/EditingBehaviorsSupport.swift:120` |

### 2.5 Tests and evidence infrastructure

| Fact | Evidence |
|---|---|
| About 339 `AppState(` constructions in `AppTests`, plus `PerformanceTests`. | `git grep -c "AppState(" -- AppTests`; `PerformanceTests/AppBackedEditorPerformanceTests.swift:223` |
| UI tests pick "the" window as the first hittable one and query identifiers app-wide. | `PlainsongUITests/EditorFindAcceptanceTests.swift:119-129`, `PlainsongUITests/WorkspaceSearchAcceptanceTests.swift:29-37` |
| Accessibility identifiers are not unique across windows. | `App/Views/WorkspaceWindow.swift:200` |
| Real dual-window key activation has never been verified. | `docs/editor-find-gates.md:776-781`, `docs/decision-log.md:180` |
| The memory gate is 8 warm sessions + 2 live webviews under 400 MB host RSS. Recorded runs: 141.6–149.8 MB host, with about 500 MB across two WebKit helpers (diagnostic, R16). | `PerformanceTests/PerformanceBudgetTests.swift:309`, `:431`, `docs/perf-log.md:51`, `:69`, `docs/risk-register.md:26` |
| The typing-latency gate. | `PerformanceTests/PerformanceBudgetTests.swift:12` |

## 3. State partition

### 3.1 Scopes

| Scope | Owner (names non-binding) | Lifetime |
|---|---|---|
| Per window | `WindowState` | One window or tab. |
| Per workspace root | `WorkspaceRootContext`, reference-counted by windows | First window that opens the root → last window that releases it. |
| Per document file | Entries keyed by `ObjectIdentifier(DocumentSession)` or by canonical URL inside the app-global registry | The session's lifetime. |
| App-global | `AppDocumentRegistry`, `KeyWindowRouter`, services | The process. |

Per-file state is stored in the app-global registry, not in a window: the §3.4 invariants
and the LRU must see all of it. "Per file" is a key, not a separate owner.

### 3.2 Every `AppState` stored property

Line numbers are in `App/AppState.swift`.

| Properties (line) | Scope | Reason |
|---|---|---|
| `currentDocument` (148), `documentChangeCancellable` (282) | Window | The window's document and its publish forwarding. |
| `layoutMode` (153), `wysiwygFallbackMessage` (192) | Window | Per-window layout. New windows inherit the last persisted value (WD9). |
| `editorFocusRequestID` (193), `editorNavigationCommand` (173), `editorNavigationGeneration` (235) | Window | They target that window's editor. |
| `editorFindHost` (172): controller, `ui`, match highlight, selection cache, chrome focus, test overrides | Window, **except** `replaceAuthority.generation` | A Find session binds one installed editor. The generation is advanced by app-global fences too; one app-global monotonic counter supersedes plans at least as often as today. |
| `workspaceRootURL` (154) | Window (a reference into a root) | Which root the window shows. |
| `workspaceTree` (155) | Split: root node → root; `expandedNodeIDs` and `selectedNodeID` → window | `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceFileTree.swift:158-160`. |
| `showAllFiles` (174) | Window | A view filter. |
| `workspaceSnapshot` (156), `workspaceSearchRootAuthority` (157), `workspaceInstalledCaptureGeneration` (161), `workspaceGeneration` (162), `workspaceReloadTask` (216), reload hooks (218, 220, 222) | Root | One scan, authority, and generation per root. |
| `workspaceAccess` (285), `workspaceWatcher` (286) | Root, reference-counted | One security scope and one FSEvents stream per root. |
| `workspaceSearchState` (163), `workspaceSearchUI` (166), `workspaceSearchFocusKeyEpoch` (169), `workspaceSearchFocusKeyWindowCheck` (171), `workspaceSearchTask` (231), `workspaceSearchTaskToken` (232), `workspaceSearchQueryGeneration` (233), `workspaceSearchRefreshIntent` (234), `workspaceSearchPostActivationHook` (224) | Window | Each window keeps its own query, results, and focus. The root generation invalidates results. |
| `completionWorkspace` (175), `completionWorkspaceTask` (279) | Window | Built from the root snapshot plus the window's current document. |
| `presentedError` (177) | Window | Alerts are per window. App-global failures go to the key window. |
| `externalChangePrompt` (178), `missingFilePrompt` (182), `indeterminateFileWriteReconciliationPrompt` (186) | Window projection of per-file state | Shown for the window's own document. The maps behind them are per file. |
| `isSaving` (152) | File | A save belongs to its session. Windows project it. |
| `autosaveTask` (214), `statisticsTask` (215), `sessionAutosaveTasks` (280), `sessionStatisticsTasks` (281) | File | The foreground split assumes one current document (`App/AppState+Autosave.swift:27-66`). Merge into per-session tasks. |
| `editorDocumentBindingIDs` (236), `editorDocumentBindingSessions` (237), `editorBindingInstallations` (238), `editorWriterInstallations` (244), `pendingEditorSourceInstallations` (245), `editorDocumentSourceSynchronizers` (276), `editorDocumentSourceFullComparisonCounts` (273) | File | WS3B one-writer authority must see every installation in every window. |
| `retiredEditorDocumentSessions` (272), `sessionLifecycleGenerations` (288) | File | Retirement outlives windows. |
| `deferredExternalChangeResolutions` (251), `externalResolutionIntentCaptures` (255), `externalReloadTasks` (256), `externalDiskInspectionTasks` (260), `pendingExternalReloadApplications` (264), `nextExternalReloadGeneration` (270), `externalDiskEventGenerations` (271), `lastKnownDiskHashes` (290), `lastKnownDiskModificationDates` (291), `pendingExternalTexts` (292), `pendingExternalFileVersions` (300), `detachedSessionURLs` (304) | File | One disk truth per file. |
| `anchoredSessionFileBindings` (310), `unanchoredManagedSessionOwnershipProofs` (313), `editorImageAssetDocumentAuthorities` (318), `indeterminateSessionWrites` (321), `indeterminateSessionWriteContexts` (326) | File | Authority and quarantine belong to the file. |
| `sessionCache` (287), `sessionPolicy` (289) | App-global | One warm set and one LRU (WD6). |
| `workspaceMutationWriteFences` (329), `workspaceMutationNamespaceDepth` (335), `workspaceMutationRefreshPending` (338), `workspaceMutationExternalRefreshPending` (341), `workspaceMutationRefreshRootAuthority` (344), `workspaceImageAssetInsertionCount` (347), `editorImageAssetDiscardEventHandler` (349) | App-global in v1 (one namespace transaction at a time, which records its root) | A fence must stop a save from whatever window shows the session. `endWorkspaceNamespaceMutation` clears every fence (`App/AppState+WorkspaceMutationTransaction.swift:58`), so per-root concurrent transactions need a separate design. |
| `indeterminateWorkspaceMutationSessions` (353), `workspaceMutationRecoveries` (357), `workspaceMutationOperationRecoveryRecords` (358), `workspaceMutationOperationRecoveryIDsWithUnpromotedText` (360), `workspaceMutationRecoveryIDBySession` (361), `workspaceMutationTextRecoveryContexts` (362), `workspaceMutationTextRecoverySessions` (364), `workspaceMutationTextRecoveryTasks` (365), `pendingWorkspaceMutationTextRecoveryRecords` (366), `pendingWorkspaceMutationOperationRecoveryRecords` (368), `workspaceMutationRecoveryLoadErrors` (370), `workspaceMutationOperationRecoveryLoadError` (371), `workspaceMutationTextRecoveryLoadError` (372), `workspaceMutationOperationRecoveryLoadFailed` (373), `workspaceMutationTextRecoveryLoadFailed` (374), `workspaceMutationReconciliationPrompt` (188) | App-global | The durable stores are single files. One loader, one fence, one prompt. |
| `fileWriteArtifactNotices` (190), `workspaceTrashCleanupNotices` (191), `recentItemURLs` (176) | App-global | Outcomes of app-wide write paths, and one recents list. |
| `shouldRestoreLastOpenedFile` (283), `didAttemptRestore` (284) | App-global | Restoration runs once per launch, not once per window (§6.4). |
| `preferences` (375), `isWYSIWYGMechanismHealthy` (376), `userDefaults` (211) | App-global | One settings source. A mechanism failure is process-wide. |
| `fileStore` (197), `coherentFileReader` (198), `externalReloadApplicationPreparer` (199), `lastOpenedFileStore` (200), `recentItemStore` (201), `directoryScanner` (202), `workspaceSearchStreamProvider` (203), `workspaceSearchLimits` (204), `workspaceSearchDebounceNanoseconds` (205), `fileOperations` (206), `workspaceMutationOperationRecoveryStore` (207), `workspaceMutationTextRecoveryStore` (209), `reportedTrashBookmarkAccess` (210), `editorImageThumbnailAdapter` (212), `anchoredFileSaveOverride` (226) | App-global | Injected services and a test seam. |
| `editorImageThumbnailRefreshProxy` (213) | Root | It fans out by workspace-relative path. |

### 3.3 Process-wide statics outside `AppState`

| Static | Evidence | Target |
|---|---|---|
| `PlainsongAppServices.appState` | `App/PlainsongAppServices.swift:7-10` | Removed. `KeyWindowRouter` resolves the key window's `WindowState`; the registry serves app-global needs. |
| Hot-key handler and registration | `App/PlainsongApplication.swift:12-18` | Stays app-global. Its action resolves the key window (§5.1). |
| `EditorFindActionHooks` | `Packages/EditorKit/Sources/EditorKit/EditorFindActionHooks.swift:6-14` | The hooks receive the originating text view's window (an EditorKit API change). |
| `EditorSelectionProbe.keyWindowOverrideForTesting` | `Packages/EditorKit/Sources/EditorKit/EditorSelectionProbe.swift:120` | Unchanged. |
| `EditorCommandResponderRegistry.routes` | `Packages/EditorKit/Sources/EditorKit/EditingBehaviorsSupport.swift:120` | Unchanged (keyed per text view). |
| `WorkspaceDirectoryCloneSourceRegistry.shared` | `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceItemCreationTypes.swift:24-28` | Unchanged (lock-protected). |
| `AppState.exportAppPrivateRoot(environment:homeDirectory:)` | `App/AppState+ExportAppPrivateRoot.swift:9-26` | Unchanged (a pure static of the process environment). |

### 3.4 Safety invariants that must stay global

| ID | Invariant | Rule |
|---|---|---|
| I1 | One writer per file. | At most one `editorWriterInstallations` entry per session across all windows (`App/AppState+EditorBinding.swift:444-450`). Under WD1, at most one window installs a given physical file. |
| I2 | Every ownership inventory spans all windows. | Save Copy, export, mutation destination, retained-authority collision, physical duplicate, LRU protection, workspace closure, and termination all read **one** registry enumerator that replaces the eight lists in §2.3. List-specific extras (recovery sessions, text-recovery sessions) stay explicit. Save Copy, export, and mutations then refuse a destination owned by any window. |
| I3 | Recovery and quarantine fences are global. | Each durable store loads once. A load failure fences file access in every window. Pending recovery blocks restoration of every window. A quarantined session refuses writes from every window. |
| I4 | The workspace write fence spans windows that share a root. | A namespace transaction fences every session under its root whichever window shows it (`App/AppState+WorkspaceMutationTransaction.swift:40-48`), and a second transaction from any window is refused (`:24-26`). |
| I5 | One termination check. | `prepareForTermination` covers every window's sessions. |
| I6 | One writer for app-wide bookmarks. | Recents, the restoration store, and the legacy last-opened key. |

## 4. The same file or the same workspace in two windows

### 4.1 Same file (WD1)

"Same file" means the same retained location or the same physical identity: the canonical
session key (`App/AppState+Workspace.swift:371-376`) plus
`hasConflictingPhysicalSessionOwnership` (`App/AppState+WorkspaceSessions.swift:309-336`).
Hard links and case or normalization aliases count. A file is "open in a window" when its
session is that window's current document. Warm LRU sessions belong to no window: a window
may adopt one when no other window shows it.

| Option | Behavior | What it needs | Risks |
|---|---|---|---|
| **(a) Focus the existing window — recommended** | A request that would make file F current in window B while window A shows F brings A (and its tab) to the front. B is unchanged. No error. | A registry lookup from installed file to window, and `makeKeyAndOrderFront` or tab selection. | A sidebar click in B jumps to another window. Every entry point must be routed (W4). |
| (b) Share one `DocumentSession` | B installs a second editor for the session, with its own selection and scroll. | Live per-keystroke propagation to the other installation (today a non-writer converges only at its next activation, `App/AppState+EditorBinding.swift:433-441`). A shared undo model (today each view has its own `CoalescingUndoManager`). IME: marked text in A while B publishes. Per-view WYSIWYG fold and thumbnail presentation over shifting ranges. Find/Replace authority per window over one session (the editor stamp includes window and selection, `Packages/EditorKit/Sources/EditorKit/EditorReplaceCommandDispatcher.swift:10-15`). One external-change prompt resolved from two banners. One autosave. | Cross-window work on every keystroke (§12 typing gate), undo corruption, and the highest review cost. Not for v1. |
| (c) Refuse | An error: "already open in another window". | Least code. | Hostile: the user must find the window. Kept only as the fail-closed fallback when focusing is impossible (the target window is mid-close or has a sheet). |

**Recommendation: (a).** It keeps I1 trivially, because each physical file has one
installation and therefore one writer candidate. It keeps undo, IME, WYSIWYG, and
Find/Replace exactly as they are in one window. It adds no per-keystroke work. It matches
Typora and the NSDocument convention: reopening an open document brings its window
forward. Residual risk: two opens of one file race only on the main actor, which
serializes them, and a closing window stops owning its file once its close has committed
(§6.2).

### 4.2 Same workspace root (WD2)

| Option | Behavior | What it needs | Risks |
|---|---|---|---|
| **(i) Shared root context — recommended** | One `WorkspaceRootContext` per canonical root: one security scope, one watcher, one scan snapshot and generation, one mutation fence that covers sessions in every window, and one image-placement fence. Each window keeps its own current document, expansion, selection, Show All Files, and search. Closing a window releases its reference; the last release runs today's closure semantics. | Split `WorkspaceFileTree` (`Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceFileTree.swift:158-160`). Closure becomes a release, and must not empty other windows' sessions (`App/AppState+WorkspaceRetirement.swift:243`, `:254`). A reference-counted scope (precedent: `App/AppState.swift:855-930`). | The most code, all in PR D. A rename in one window reloads both sidebars, which is the desired result. |
| (ii) Focus the existing window for the same root | One window per root. Opening the root again focuses that window. | The same lookup as WD1. | Tabs lose their main use (several posts of one blog as tabs). "Open in New Window" becomes impossible inside one root. |
| (iii) Refuse | An error. | Least code. | Hostile. |
| (iv) Independent duplicates | Two scans, watchers, and fences for one root. | None. | **Never allowed.** A rename in A would not fence B's session, which violates I4. |

**Recommendation: (i)**, with WD1 applied per file inside it. If the owner wants a smaller
PR D, (ii) is a safe v1 and (i) can follow: PRs B and C create the root context either way.

### 4.3 Overlapping roots and single files inside an open root

The code makes this hard. A watcher event inspects only sessions whose retained location
belongs to its root authority (`App/AppState+Workspace.swift:111-131`). An unanchored
single-file session records membership in at most one installed root
(`App/AppState+SessionOwnership.swift:496`). Recommended rules (part of WD2):

- Opening a folder that is an ancestor or a descendant of a root open in another window is
  refused: "This folder overlaps a workspace open in another window", with a Show button.
- Opening a single file that lies inside an open root opens it as a workspace document of
  that root. WD1 applies first, then WD7 decides the window.
- Opening a root that contains a file already open as a single file in another window is
  allowed. The root's installation adopts membership for that session through the existing
  `retainInstalledWorkspaceMembershipIfAvailable` path, so the watcher and mutation fences
  cover it. The single-file window keeps showing it.

## 5. Command and event routing

### 5.1 Key-window resolution and menu enablement

- **`KeyWindowRouter`** (app-global, main actor) maps each window to its `WindowState`. A
  per-window bridge like `WindowKeyStateTracker` (`App/Views/WindowKeyStateTracker.swift:30-63`)
  registers it. The router publishes `activeWindowState` only on
  `NSWindow.didBecomeKeyNotification`, `didResignKeyNotification`, or window close. When a
  non-workspace window is key (Settings, a panel, an alert), there is no active window:
  document commands disable and never fall back to the main window
  (`Packages/EditorKit/Sources/EditorKit/EditorReplaceCommandDispatcher.swift:64-70`).
- **`MenuBarState` keeps its contract** (`App/MenuBarState.swift:26-34`). It re-subscribes
  when `activeWindowState` changes. For the active window only, it observes
  `objectWillChange.receive(on: RunLoop.main)`, re-reads a `MenuBarSnapshot`, and
  republishes only on change. The snapshot holds the window facts (open document,
  `canSave`, workspace search, layout title), the app-global `recentItemURLs`, and a new
  `hasActiveWorkspaceWindow`. Background windows' publishes never reach the menu.
- **Rejected:** `@FocusedObject` / `focusedSceneObject(WindowState)` in `PlainsongCommands`.
  It observes the whole window object and brings back the high-churn menu rebuilds that
  `MenuBarState` exists to stop. A `focusedSceneValue` of the already-deduplicated snapshot
  is an acceptable alternative if W0 shows it is deterministic. It is not the default,
  because hosted tests designate key windows through AppKit (§8).
- **Actions resolve their target when invoked**, for example
  `router.activeWindowState?.save()`. `PlainsongCommands` stops capturing an `AppState`
  (`App/PlainsongCommands.swift:13`).
- **Responder-chain commands** (Format, Find) keep `sendAction(_:to: nil, from: nil)`.
  Because enablement excludes non-workspace key windows, AppKit's main-window fallback
  cannot fire. The Find hooks and the App fallbacks
  (`App/EditorFindCommandDelivery.swift:17-48`) resolve the key window's state. The EditorKit
  selectors (`Packages/EditorKit/Sources/EditorKit/EditorFindSpike.swift:68-83`) pass their
  own window, so a command reaches the window that owns the text view.
- **Carbon ⇧⌘F** stays registered app-wide while active
  (`App/PlainsongApplication.swift:57-85`). `PlainsongWorkspaceSearchKeyAction` toggles
  search on `activeWindowState` only, and still consumes the event when there is none
  (`App/PlainsongApplication.swift:103-108`).

### 5.2 Entry-point routing

"Same rule as Open" means: if the file or root is open in another window, focus it (WD1,
WD2, §4.3). Otherwise, if the key workspace window is empty (no document and no root),
open there. Otherwise open a new window (WD7). Exactly one window acts, and no blank scene
is left behind.

| Entry point | Today | Target |
|---|---|---|
| Finder Open With, Dock drop, `open -a` (`onOpenURL`) | `App/PlainsongApp.swift:51-53`; SwiftUI may also create a scene (W0) | Same rule as Open. |
| File › Open… ⌘O, toolbar Open, empty-state Open | `App/AppState.swift:575-604` | Same rule as Open. The panel is window-modal for the active window, or app-modal when there is none. |
| Open Recent | `App/PlainsongCommands.swift:34-44` | Same rule as Open. |
| Sidebar click | `App/AppState+Workspace.swift:282-299` | Same window. WD1 focus if the file is current elsewhere. |
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
| **(A) Keep ⌘N for New File; add File › New Window ⇧⌘N (and New Tab ⌘T under WD4) — recommended** | §6.4 and `docs/m4-checklist.md` stay valid. ⇧⌘N and ⌘T are unused: every App shortcut is in `App/PlainsongCommands.swift:25-138`. | It departs from apps where ⌘N opens a window. |
| (B) ⌘N for New Window; New File moves to ⌥⌘N | The stock macOS binding. | It breaks §6.4, the M4 checklist, and existing muscle memory. |
| (C) No New Window command | No new command. | Users cannot open an empty window. The tab-bar "+" depends on unverified AppKit behavior. |

## 6. Lifecycle

### 6.1 Opening a window or tab

- A new window gets an empty `WindowState`: no document, no root, the last persisted layout
  (WD9), the Find bar closed, and Files mode. It never runs launch restoration. Today every
  window's `.task` calls it (`App/Views/WorkspaceWindow.swift:79-82`).
- It creates no WKWebView until it shows a document with the preview visible (§7.2).
  Today the controller and its WKWebView are created when the editor area mounts, whether
  or not the preview is visible (`App/Views/WorkspaceWindow.swift:102`,
  `Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift:54`, `:66`).
- It registers with `KeyWindowRouter`.

### 6.2 Closing a window or tab

In order (closing a tab is closing a window):

1. **Refuse** (WD8): the window stays open and an alert explains why, if its current
   document has pending editor source or marked text (`App/AppState+EditorBinding.swift:291`),
   an unresolved external-change or missing-file prompt, an indeterminate write, a dirty
   detached or text-recovery session, or a namespace mutation in progress. These are the
   states that already refuse workspace closure and termination
   (`App/AppState+WorkspaceRetirement.swift:26-82`,
   `App/AppState+WorkspaceMutationTextRecovery.swift:300-400`).
2. **Flush:** save the current document if it is dirty and `canAutosave`
   (`App/AppState+Autosave.swift:135-156`). A saved session stays warm in the global LRU.
3. **Revoke** the window's editor installation through the existing path
   (`App/AppState+EditorBinding.swift:361-405`). This releases the writer, reconciles the
   LRU, and finishes retirement where possible.
4. **Release** the root reference. The last release runs today's closure checks and
   retirement (`App/AppState+WorkspaceRetirement.swift:16-87`), but only over sessions that
   no other window references. A single-file window inside the root keeps its session
   (§4.3).
5. **Cancel** window-owned tasks (search, completion, Find, navigation) and invalidate the
   preview controller (`Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift:153-170`).
6. **Remove** the window's restoration record, on a user close only (§6.3).

The §5 LRU guarantees stay: a failed or fenced eviction candidate stays protected for the
pass (`App/AppState+WorkspaceSessions.swift:391-410`), and the cache may exceed its limit
while saves cannot complete. Plainsong has no unsaved untitled editing: New File creates
the file first (`App/AppState+NewFile.swift:45-60`), and `hasOpenDocument` requires a URL
(`App/AppState.swift:805-807`). An untitled or recovery session therefore falls under
step 1. Closing the last window leaves the app running, as it does today.

### 6.3 Quitting

- `applicationShouldTerminate` calls one app-global `prepareForTermination()` over every
  window's sessions (`App/PlainsongApplicationDelegate.swift:42-54`,
  `App/AppState+WorkspaceMutationTextRecovery.swift:442-450`). A refusal brings the window
  that owns the blocking session to the front and shows the error there.
- Autosave flushes once. The per-window `willTerminate` observer
  (`App/PlainsongApp.swift:54-56`) moves to the delegate.
- Restoration records are written before AppKit closes the windows. Closes during
  termination do not delete records.

### 6.4 State restoration on relaunch (WD5)

**Today:** one bookmark for the last opened file or folder
(`Packages/WorkspaceKit/Sources/WorkspaceKit/LastOpenedFileStore.swift:4`), restored once
per `AppState` after recovery (`App/AppState.swift:545-573`). A restored workspace selects
its first file (`App/AppState+Workspace.swift:363-367`). Stale bookmarks are re-saved
(`Packages/WorkspaceKit/Sources/WorkspaceKit/LastOpenedFileStore.swift:38-40`).

**Proposal:** an app-owned, schema-versioned `WindowRestorationStore` in UserDefaults. It
holds an ordered list of records: an opaque window ID; the kind (workspace or file); a
security-scoped bookmark of the root or file; the workspace-relative path of the current
document; the layout mode; and the tab-group ordinal and index. It is written on open,
document switch, layout change, close (record removed), and quit (snapshot). A launch
coordinator reads it once:

1. **Recovery first.** If recovery records exist or a store failed to load, restore nothing
   else and show recovery in the first window (today's rule, `App/AppState.swift:552-562`).
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

**Mechanism risk.** SwiftUI and AppKit also recreate windows when the system setting
"Close windows when quitting an application" is off. W9's first bullet must prove exactly
one window per record with that setting on and off. `restorationBehavior(_:)` is believed
to need macOS 15, while the deployment target is macOS 14, so the probe must find a
macOS 14 path (for example `WindowGroup(for:)` presented values as record keys, or AppKit
`isRestorable`).

### 6.5 Native tabs (WD4)

- A tab is a window: one `WindowState` per tab, with AppKit tab groups. There is no custom
  tab bar and no extra state model.
- The tabbing mode is `.automatic`, which follows the system "Prefer tabs" setting. File ›
  New Tab ⌘T adds an empty window to the key window's group.
- Merge All Windows, Move Tab to New Window, and dragging between groups are pure AppKit.
  The window object, and therefore its `WindowState`, must survive them (W0 probe).
- Tab titles are window titles (§8). A hidden tab is a hidden window for preview
  residency (§7.2). Closing a tab follows §6.2. Restoration records group order (§6.4).

## 7. Performance and memory

### 7.1 Warm-session LRU (WD6)

The LRU stays **global**: 8 warm sessions plus every installed current document. Today
protected entries count toward the limit
(`Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceSessionLRUPolicy.swift:94-100`), so
N windows would leave 8 − N warm slots. PR D changes the WorkspaceKit policy so installed
URLs do not use warm capacity, with unit tests. A per-window LRU is rejected: it costs 8·N
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
  (`Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift:163-167`), so a torn-down
  preview cannot deliver a checkbox toggle. Render IDs restart per controller
  (`Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift:27`). That is safe
  because `checkboxToggled` requires the controller's latest render ID (`agent.md` §7.3).
- **Cost today:** 141.6–149.8 MB host RSS with two settled webviews, and about 500 MB in
  two WebKit helpers (`docs/perf-log.md:51`, `:69`). Helper memory is diagnostic under R16
  (`docs/risk-register.md:26`), but users feel it with many windows.

### 7.3 Restated §12 memory budget (proposal)

"< 400 MB host RSS with 8 warm sessions and 4 windows: 2 visible settled previews and
2 hidden windows past teardown." Also record, in `docs/perf-log.md`, the host RSS delta
per additional live preview and the helper RSS (diagnostic). The existing two-webview
test (`PerformanceTests/PerformanceBudgetTests.swift:309`) stays.

### 7.4 Typing latency

- There is no per-keystroke cross-window work. Under WD1 a keystroke reaches one
  installation. `DocumentSession` still does not publish text
  (`Packages/MarkdownCore/Sources/MarkdownCore/DocumentSession.swift:34-41`). Each
  `WindowState` forwards only its own document's publishes; today the one `AppState`
  forwards them to every window (`App/AppState.swift:683-688`). The registry publishes
  nothing per keystroke. `MenuBarState` observes only the active window. W12 measures this.

## 8. Accessibility and UI-test implications

- **Window and tab titles.** Today the title is the root name, else the file name
  (`App/AppState.swift:827-829`), applied with `representedURL` and `isDocumentEdited`
  (`App/Views/WorkspaceWindow.swift:439-460`). Two windows on one root would share a title
  in the Window menu, the tab bar, Mission Control, and VoiceOver. **Proposal:** the title is
  the current document's name (the root name with no document; "Plainsong" with neither),
  the subtitle is the root name, and the represented URL and edited dot stay per window. When
  two windows would have the same title (`index.md` in two roots), append " — <root name>".
  Tab titles follow window titles.
- **Accessibility identifiers** stay stable but are no longer unique in the app
  (`plainsong.editor.fileName` at `App/Views/WorkspaceWindow.swift:200`, the Find field, the
  Search mode). Every XCUITest query must be scoped to one window element.
- **UI tests to change.** `PlainsongUITests/EditorFindAcceptanceTests.swift:119-129` uses
  the app-wide `staticTexts[...]` and `.first(where: \.isHittable)`.
  `PlainsongUITests/WorkspaceSearchAcceptanceTests.swift:29-37` uses the app-wide
  `descendants`. Both must select their window by its unique title.
- **Hosted tests** keep the designated key window
  (`AppTests/EditorFindHostedFocusGateTestSupport.swift:22`). Real activation needs an
  out-of-process XCUITest in an interactive session (`docs/decision-log.md:180`). New
  Window (WD3) makes that test possible for the first time.
- **VoiceOver and Full Keyboard Access.** Switching windows announces the window title.
  Each window restores focus to its own last focused control. ⌘` cycles windows, and each
  window's Find chrome keeps its own focus report.

## 9. Owner decisions

Deadlines: WD9 before PR C; WD1, WD2, WD3, WD6 (LRU part), WD7, and WD8 before PR D; WD5
before PR E; WD4 before PR F; WD6 (residency and budget) before PR G. Silence, an
implementation, or green CI is not a decision.

| # | Question | Options | Recommended default | Consequences |
|---|---|---|---|---|
| WD1 | The same file in two windows | (a) focus the existing window; (b) share one session; (c) refuse | **(a)**, also for sidebar clicks and preview links | I1 holds trivially. No undo, IME, or typing-path change. (b) needs its own spec. |
| WD2 | The same workspace root in two windows | (i) shared reference-counted root context; (ii) focus the existing window; (iii) refuse | **(i)**, plus refusal of overlapping roots and the §4.3 single-file routing | PR D splits the tree and turns closure into a release. (ii) is the smaller fallback. |
| WD3 | ⌘N versus New Window | (A) ⌘N New File + ⇧⌘N New Window; (B) ⌘N New Window; (C) no command | **(A)** | §6.4 gains rows; none move. |
| WD4 | Are tabs in scope for this line? | Yes, as PR F; defer (then set tabbing to disallowed so tabs cannot mirror) | **Yes**, `.automatic` mode, ⌘T | WD2 (i) is what makes tabs useful. |
| WD5 | Restoration | Restore every window and tab with document and layout; restore only the frontmost (today's single bookmark); follow the system setting only | **Restore every window**; skip missing items with one notice; recovery first | Needs the W9 mechanism probe. |
| WD6 | Preview and memory policy | Lazy, visible always live, two hidden within a 30 s grace; always live with a window cap; per-window LRU | **The first**, plus a global LRU of 8 warm + installed and the restated §12 budget (§7.3) | Re-showing a torn-down preview costs one cold render. |
| WD7 | Where an external open lands | A new window unless the key window is empty; always the key window (today's behavior); always a new window | **A new window unless the key window is empty** | Matches Typora and NSDocument. |
| WD8 | Closing a window whose document cannot be saved safely | Refuse the close with an explanation; close and keep the session invisible | **Refuse** | No invisible unsaved state. |
| WD9 | Layout mode and Find query scope | Per window, new windows inherit the last persisted layout; global | **Per window** | M2's "layout restored on relaunch" moves into the WD5 records. |

## 10. Review-sized PR split

One PR at a time, each branched from then-current `origin/main` and opened against `main`.
The maintainer squash-merges. PR B touches every `AppState` extension, so schedule it after
the in-flight Replace F and G work lands, or coordinate with that stream first.

| PR | Scope | Expected gates | Security review |
|---|---|---|---|
| **A — this spec** | `docs/window-state-gates.md` and one Decision Log row. No code, test, or checked box. | None | No |
| **B — mechanical partition** | Introduce the registry, root-context, and window-state types. `AppState` stays the façade for one window, so the ~339 test constructions compile. One session enumerator feeds the eight inventories. No behavior change, no new publish, still one window. Record the W0 inventory. | W0 (inventory bullet), W1 | **Yes**: it moves ownership-inventory, recovery, and quarantine code. |
| **C — per-window state and key-window routing** | One `WindowState` per window, proven with hosted multi-window tests. The shipped app stays single-window: no New Window, and external opens reach the one window. `MenuBarState` follows the key window. `PlainsongAppServices` is removed. The hot key, Find hooks, and Find/Replace fallbacks route by window. Find, search, layout, and prompts are per window. Restoration runs once per launch. | W0 (mechanism bullets), W2, W3, W5 | **Yes**: writer authority and ownership across windows. |
| **D — policies and window creation** | WD1, WD2, and §4.3 routing; root reference counting and retirement on last release; overlap refusal; New Window ⇧⌘N; the §5.2 external-open table; the §6.2 close lifecycle; the LRU policy change. | W4, W6, W7, W8 | **Yes**: mutation fences, retirement, ownership. |
| **E — restoration** | The restoration store, migration, the mechanism probe, and missing-item handling. | W9 | **Yes (light)**: security-scoped bookmarks. |
| **F — native tabs** | Tabbing mode, New Tab ⌘T, title rules, merge and move. | W10 | No |
| **G — residency and acceptance** | Preview residency, out-of-process dual-window XCUITest, multi-window memory and typing measurements, accessibility. | W11, W12, W13 | No. Residency must not touch the bridge. |

Order: B → C → D → (E and F in parallel) → G. Before declaring an implementation PR done:
the relevant package and hosted tests, `make format`, `make lint`, `make test`,
`make build`, and `git diff --check`. The PR body lists the gates closed and still open.

## 11. Gates

Boxes start unchecked. Each bullet names the evidence it needs: a named hosted test, a
named XCUITest, a perf measurement recorded in `docs/perf-log.md`, or an owner smoke
recorded in the closing commit.

### W0 — Baseline inventory and mechanism probe

- [ ] On the shipped build, record which actions create a second window today: the tab-bar
  "+", Window › Merge All Windows and Show Tab Bar, Finder Open With while running, and a
  Dock drop. *Owner smoke.*
- [ ] The chosen external-open mechanism delivers each Finder or Dock open to exactly one
  existing window and leaves no blank scene. *Hosted probe + owner smoke.*
- [ ] A window's `WindowState` identity survives tab merge, tab move, and `openWindow`
  creation, and `openWindow` from `Commands` creates a fresh `WindowState`. *Hosted probe.*
- Evidence: _open_

### W1 — Behavior-neutral partition (PR B)

- [ ] Every `AppState` stored property lives in the scope §3.2 assigns. *Review checklist
  in the PR body.*
- [ ] One registry enumerator feeds all eight inventories. A test registers a session only
  in a second `WindowState` and proves each inventory sees it. *Named hosted test.*
- [ ] All existing package, `AppTests`, and `PerformanceTests` tests pass with mechanical
  renames only.
- [ ] No new publish on the keystroke path: the typing test is unchanged within noise.
  *Perf measurement.*
- [ ] `App/AppState.swift` and every new file stay under the 1000-line SwiftLint error and
  near the ~400-line guidance.
- Evidence: _open_

### W2 — Two windows never mirror each other's document

- [ ] Two production `WorkspaceWindow`s with separate `WindowState`s open `A.md` and
  `B.md`. Editor text, preview render, window title, file header, Find bar visibility and
  query, search mode and results, banners, and layout are independent. Switching the
  document in window 1 leaves window 2 untouched. *Named hosted test.*
- [ ] The same holds for two different roots. *Named hosted test.*
- [ ] An external change to `A.md` shows its banner only in the window showing `A.md`.
  *Named hosted test.*
- [ ] The first bullet passes out of process (PR G). *Named XCUITest.*
- Evidence: _open_

### W3 — Ownership refusals are cross-window

- [ ] Save Copy from window 1 onto the file current in window 2 is refused, including a
  hard link and a case alias. *Named hosted test.*
- [ ] An export destination owned by window 2 is refused
  (`validateExportArtifactDestinationOwnership`, through both its Save Copy and mutation
  inventories). *Named hosted test.*
- [ ] A mutation destination owned by a window-2 session is refused
  (`validateWorkspaceMutationDestinationOwnership`). *Named hosted test.*
- [ ] The retained-authority collision and physical-duplicate checks see window-2 sessions.
  *Named hosted test.*
- [ ] Termination refuses for a blocked session in a background window and brings that
  window forward. *Named hosted test.*
- [ ] A recovery-store load failure fences file access in every window. *Named hosted test.*
- Evidence: _open_

### W4 — One writer per file across windows

- [ ] Every §5.2 entry point that targets a file current in another window focuses that
  window and creates no second installation. *Named hosted tests, one per entry point.*
- [ ] Hard links and case or NFC/NFD aliases count as the same file. *Named hosted test.*
- [ ] For every session, live installations across windows ≤ 1 and
  `editorWriterInstallations` ≤ 1. *Debug assertion + named hosted test.*
- [ ] A warm session adopted by window 2 after window 1 switched away transfers the writer;
  window 1's stale installation cannot publish. *Named hosted test.*
- Evidence: _open_

### W5 — Menu commands act only on the key window

- [ ] With window 2 key, Format, Find (⌘F, ⌘G, ⇧⌘G, ⌘E), Replace, Save, ⇧⌘P, Toggle
  Workspace Search (menu and Carbon), and New File act on window 2. Window 1's source,
  selection, undo stack, and Find query are unchanged. *Named hosted tests with a
  designated key window.*
- [ ] With Settings key and a workspace window main, document commands are disabled and ⌘B
  does not reach the main window's editor. *Named hosted test.*
- [ ] Menu enablement follows the key window within one run-loop pass. Background-window
  publishes do not republish the snapshot. *Named hosted test with a publish counter.*
- [ ] A Find hook fired from a text view reaches its own window's state. *Named hosted
  test.*
- Evidence: _open_

### W6 — Same-workspace shared root context

- [ ] Two windows on one root share one watcher, one security-scope start, and one scan
  per refresh. *Named hosted test.*
- [ ] A rename in window 1 of the file current in window 2 relocates window 2's session.
  Window 2's saves are refused during the fence. Both trees update, and each keeps its own
  expansion and selection. *Named hosted test.*
- [ ] Closing window 1 keeps the root alive. Closing the last window runs the closure checks
  once. A single-file window's session inside the root survives. *Named hosted test.*
- [ ] An overlapping root is refused, and a single file inside an open root routes per §4.3.
  *Named hosted test.*
- [ ] A second namespace transaction, from any window or root, is refused while one runs.
  *Named hosted test.*
- Evidence: _open_

### W7 — Window close lifecycle

- [ ] A dirty, savable document is saved and stays warm. *Named hosted test.*
- [ ] Each blocking state in §6.2 step 1 refuses the close with an alert, the window stays,
  and nothing is lost. *Named hosted tests.*
- [ ] The installation is revoked, the writer released, and the LRU reconciled; a failed
  eviction candidate is still retained (§5). *Named hosted test.*
- [ ] The preview controller is invalidated and released (its weak reference becomes
  `nil`). *Named hosted test.*
- [ ] A user close removes the restoration record; a quit does not. *Named hosted test.*
- Evidence: _open_

### W8 — External-open and ⌘N routing

- [ ] Every §5.2 row: focus the existing window, reuse an empty key window, or open a new
  window. Exactly one window acts and none is left blank. *Named hosted tests + owner smoke
  for Finder and Dock.*
- [ ] ⌘N creates a file in the key window's root. ⇧⌘N opens an empty window that does not
  restore. *Named hosted test.*
- Evidence: _open_

### W9 — Restoration

- [ ] Exactly one window per record, with the system "Close windows when quitting" setting
  on and off, on macOS 14 and the current macOS. *Owner smoke (mechanism probe).*
- [ ] A mix of workspace and single-file windows restores each root or file, current
  document, layout, and tab order. *Named hosted test + owner smoke.*
- [ ] A missing or unresolvable bookmark is skipped with one notice, no empty window, and no
  panel. *Named hosted test.*
- [ ] With recovery pending, nothing else is restored. *Named hosted test.*
- [ ] The legacy single bookmark migrates to one record. *Named hosted test.*
- [ ] Records that break WD1 or WD2 collapse to the first. *Named hosted test.*
- Evidence: _open_

### W10 — Native tabs

- [ ] New Tab ⌘T joins the key window's group, and every W2 bullet holds between tabs.
  *Named hosted test + owner smoke.*
- [ ] Merge All Windows, Move Tab to New Window, and dragging a tab keep each tab's document,
  selection, undo stack, and Find state. *Owner smoke.*
- [ ] Tab titles are unique per §8, and closing a tab follows §6.2. *Named hosted test.*
- [ ] A background tab's preview follows §7.2 residency. *Named hosted test.*
- Evidence: _open_

### W11 — Memory

- [ ] The §7.3 configuration stays under 400 MB host RSS. Helper RSS and the per-preview
  host delta are recorded. *Perf measurement in `docs/perf-log.md`.*
- [ ] Hidden previews beyond two are torn down after the grace period (controller
  released), and visible previews are never torn down. *Named hosted test.*
- [ ] The LRU keeps 8 warm sessions plus the installed ones, and
  `testZZZMemoryWithEightWarmSessionsAndTwoLiveWebViewsStaysUnderBudget` still passes.
  *Named tests.*
- Evidence: _open_

### W12 — Typing latency

- [ ] The §12 typing test with four windows open (two previews visible) stays under 16 ms.
  Three Debug and three Release runs are recorded. *Perf measurement.*
- [ ] Zero body evaluations or `objectWillChange` sends in other windows per keystroke.
  *Named test with an instrumented counter.*
- Evidence: _open_

### W13 — Accessibility and out-of-process acceptance

- [ ] Two windows opened with New Window, real key activation, menus act on the frontmost
  window, and every selector is scoped to a window. *Named XCUITest.*
- [ ] VoiceOver reads distinct window titles, and Full Keyboard Access reaches each window's
  Find chrome. *Owner smoke.*
- [ ] The existing UI tests use window-scoped queries and still pass. *Named XCUITests.*
- [ ] Zhuyin and Pinyin composition in window 2 while window 1 holds marked text corrupts
  neither (`agent.md` §13). *Owner smoke.*
- Evidence: _open_

## 12. Risks and `agent.md` edits for implementation

### 12.1 Risks

| Risk | Where | Mitigation |
|---|---|---|
| SwiftUI scene behavior (external events, restoration, tab merge) differs from its documentation or between macOS 14 and current macOS. | §2.1, §6.4, §6.5 | W0 and W9 mechanism bullets close before any code relies on them. |
| PR B is large and collides with the Replace and Find streams. | Every `AppState` extension | Mechanical only; `AppState` stays the façade; schedule after Replace F and G. |
| A missed inventory weakens a cross-window refusal. | §2.3, I2 | One enumerator, W3 tests, security review on B, C, and D. |
| `endWorkspaceNamespaceMutation` clears every fence. | `App/AppState+WorkspaceMutationTransaction.swift:58` | One app-global namespace transaction in v1 (§3.2). |
| Memory grows with many windows, mostly in WebKit helpers. | §7 | Lazy creation, hidden teardown, the restated budget, R16 diagnostics. |
| Fan-out publishes regress typing latency. | §7.4 | W12 counter. |
| Hosted tests cannot activate real windows. | §8 | Designated key windows for routing; the W13 XCUITest for activation. |
| Overlapping roots break watcher and fence coverage. | §4.3 | Refused in v1. |

### 12.2 `agent.md` edits the implementation PRs must make

| Section | Edit | PR |
|---|---|---|
| §3 | The `AppState.swift` layout comment ("open workspaces, recent items") describes the registry, root-context, and window-state split. | B |
| §4 | Key types gain `WindowState`, `AppDocumentRegistry`, `WorkspaceRootContext`, and `KeyWindowRouter`. Data-flow item 6 ("on window resign") becomes one app-global flush. | B, C |
| §5 | Replace the "Multiple workspace windows … mirror" bullet with WD1, WD2, and §4.3. State that the LRU is global (8 warm + installed). Add close and quit rules and per-window restoration. | D, E |
| §5 | Replace the "Tabs … deferred" bullet with native tabs per WD4. | F |
| §6.4 | Add New Window ⇧⌘N and New Tab ⌘T. State that every menu command acts on the key window and never falls back to the main window. | C, D, F |
| §12 | Restate the memory row (§7.3). Measure typing with several windows open. | G |
| §14 | Move "window tabs" out of Phase 3 candidates. | F |
| §16 | UI tests use window-scoped selectors and include a dual-window smoke. | G |

## 13. Sign-off

| Role | Responsibility |
|---|---|
| Implementer | Close W0 mechanism bullets before relying on them; named evidence for every checked W-gate; keep layering (`agent.md` §17.3) and the §3.4 invariants. |
| Owner | Record WD1–WD9 by their deadlines; run the W0, W8, W9, W10, and W13 smokes. |
| Maintainer | Review and squash-merge each PR after green CI, with a security review for B–E. Never permit a self-merge or a direct push to `main`. |
