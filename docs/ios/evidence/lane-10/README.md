# Lane 10 — iPhone／iPad 自適應 App shell：交付摘要

> Historical raw evidence and replay files referenced below are preserved at `e20162e5`. See the [archive index and restoration instructions](../README.md); run historical local-path commands from that restored checkout.

日期：2026-10-08。契約版本：**IOS-C0-v1**（`refs/tags/ios-c0-v1`，`642cb21`）。

## 交付格式

| 項目 | 值 |
|---|---|
| Branch | `phase3-ios-adaptive-shell` |
| Worktree | `/private/tmp/plainsong-ios-adaptive-shell` |
| Base SHA | `642cb212703220409874a2741c5adbfb8c80fe8a`（公布之 `IOS_BASE_SHA`，worktree 以此重建） |
| Head SHA | 本檔所在 commit；以 `git rev-parse phase3-ios-adaptive-shell` 為準 |
| PR | **未開** — 待 13 公布的 integration 目標分支後開立（不自行 merge） |
| 實際修改路徑 | `AppIOS/UI/**`（8 files）、`AppIOS/Navigation/**`（3 files）、`AppIOSTests/Shell/**`（5 files）、`docs/ios/evidence/lane-10/**` |
| Contract 版本 | IOS-C0-v1；只讀消費，未改任何 contract／manifest |
| Named tests | 29 tests 全數通過（iPhone 17 Pro simulator, iOS 27.0）；見下節 |

## 已實作（owned paths 內）

`AppIOS/UI/`：`IOSContentLayout`（純 900 pt policy，不靠 device model）、
`IOSSceneHostedViews`（capability-identity 鍵控的 retained host cache）、
`IOSEditorPreviewContainer`（UIKit 雙掛載 container，mode 只改 geometry/visibility）、
`IOSShellSceneState`（per-scene ObservableObject；facade observation→dedup chrome）、
`IOSChromeProjection`（`IOSShellChromeSnapshot`／`IOSShellError`／`IOSShellRoute`）、
`IOSShellActionRouter`（scene-scoped，非 singleton；`IOSShellActionOutcome` 可測）、
`IOSShellFeatureSurfaces`（08/09/13 未凍結接點的 closure seam＋`IOSShellSheetContext`）、
`IOSDocumentScreen`＋`IOSDocumentStatusChrome`＋`IOSAuthoringToolbar`（含 ⌘S/⌘F/⌘Z/⇧⌘Z、
`.keyboard` group、Format overflow menu）。

`AppIOS/Navigation/`：`IOSShellRootView`（compact `NavigationStack` ↔ regular
`NavigationSplitView`；scenePhase `.background`→`flushForBackground`）、
`IOSWorkspaceBrowser`（OutlineGroup list、availability dimming、New File／Open／Refresh）、
`IOSWorkspaceQueries`（`parentDirectoryLocation`、depth-first lookup）。

`AppIOSTests/Shell/`：`IOSShellTestDoubles`（`FakeSceneFacade`／`FakeEditorBinding`／
`FakePreviewController`／`FakeAuthoringProvider`／`FakeImageInserter`／`ShellFixtures`）
＋四個測試檔共 29 tests。

## Named acceptance tests — 結果

| 測試 | 結果 |
|---|---|
| `testShellUsesSingleEditorAndPreviewAcrossLayoutChanges` | ✅ 60 次切換零 detach/attach；factory 各恰 1 次；container 保留同一 UIView |
| `testLayoutTransitionRetainsSelectionScrollAndUndo` | ✅ selection/visibleRange/selectionGeneration/markedText 逐位相等；version 不變；undo 仍路由到同一實體 |
| `testToolbarUsesCurrentSceneEditorAndRefusesReadOnlyDocument` | ✅ provider 收到同實體 editor；`updateAccess(canWrite:false)` 後 `.disabled`、chrome 顯示唯讀、零寫入 |
| `testDismissedSheetDoesNotCommitPendingEdit` | ✅ dismiss→`onDismiss` 恰一次；provider/editor/inserter 零呼叫；version 不變 |
| Simulator smoke（直橫向／900pt／resizing／實體鍵盤／composing／VoiceOver） | ⏳ owner gate——doubles 不能宣稱 |

加跑負面探針（全綠）：conflict 禁寫、stale `setCommandFocus` 拒絕、detach 後 drop、
sheet 替換／文件切換恰一次 cancel、scene 狀態非 app-global、899/900 邊界、
capability 換 identity 才換 host。

## 驗證證據

- `Scripts/ios/c0.sh test`，`IOS_DESTINATION=platform=iOS Simulator,id=59CB04BD-26CC-4841-8D06-E75A2EDEBC66`（iPhone 17 Pro, iOS 27.0, SDK 27.0）
- Run 目錄：`/private/tmp/plainsong-ios-c0/<head>-test.RGxemz`（`source.json`／`build.log`／`test.log`／`Results.xcresult`）；PlainsongIOSTests 35/35、MarkdownCore/SyntaxKit/WorkspaceCore/EditorKitIOS/WorkspaceKitIOS consumer suites 全過
- 過程中發現並修正一個真 bug：`setPanes` 未重跑 visibility→初始掛載於非預設 mode 會亮錯 pane（`testContainerVisibilityTracksModeWithoutUnmounting` 捕獲）
- `swiftformat AppIOS/UI AppIOS/Navigation AppIOSTests/Shell --lint`：0 違規；`swiftlint` 我負責路徑：0 violation

## Wiring 解析（對照 `wiring-requests.md`）

| # | 狀態 |
|---|---|
| W1–W3 | ✅ C0 交付：`PlainsongIOS` target、`AppIOSTests` scheme、`IOSAppSceneControlling` facade |
| W6, W8 | ✅ C0 交付：`IOSAuthoringAction/Providing`、`IOSSceneCapabilities.editor`＋`setCommandFocus(expected:bindingID:)` |
| W4, W5, W7 | ⚠️ 未凍結具體名稱 → shell 以 `IOSShellFeatureSurfaces` 的 hosted-view factory closures 接（04/07/08/09 由 13 在 composition 注入） |
| W9–W12 | ✅ 採用預設：hidden preview 繼續 render、無 scroll sync、doc switch 關 sheet、compact 預設 source |
| W13–W16（新） | ⏳ 記在 surfaces：`currentGrant`（image context）、`resolveConflictCopy`（`.saveCopy(destination:lease:)` 需要 lease）、`refreshWorkspace`、`openWorkspace`（picker grant 必須來自使用者選擇） |

## 關卡分列

- **已關閉：** lane-10 全部可 double 驗證的關卡（instance retention、layout policy、scene-scoped routing、cancel≠commit、facade delegation、chrome dedup、error surfacing）。
- **待整合（13／provider lanes）：** `makeEditorView`（04）與 `makePreviewView`（07）的具體型別接線；`makeAuthoringPanel`/`makeImagePicker` 內容注入（08/09）；`currentGrant`／`resolveConflictCopy`／`refreshWorkspace`／`openWorkspace` 的 composition 來源；`IOSShellRootView` 掛進 `PlainsongIOSApp` scene（`AppIOS/App` 屬 13）；多 scene 化（`UIApplicationSupportsMultipleScenes` 目前 false——shell 設計已是 scene-scoped）。
- **Owner-only 真機：** rotation 中鍵盤/marked-text 保留、外接鍵盤 shortcut discovery、中文 composing 切版、VoiceOver 走查、44pt 觸控、Dynamic Type、iPad Split View/Stage Manager 實際 resize、Undo 在真 editor 的保留。

## 不做的事（已核對）

- `git status` 確認零改動於 `AppIOS/App`／`State`／`Composition`、任何 Package、`App/**`（mac）、`project.yml`、Makefile、CI、`agent.md`、decision log、他線目錄。
- shell 無任何直接 `DocumentSession`/UITextView 寫入；唯一寫入路徑是 provider→`editor.apply(_:)`；無 shadow source、無 fake save success。
