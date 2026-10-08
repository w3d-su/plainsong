# Lane 10 來源調查 — macOS shell 盤點 → iOS 設計輸入

基準：`2144c46`（snapshot `b13aa62`）。目的：實作前盤點既有 shell 機制中可移植的模式、
不可移植的部分、以及 iOS 必須新增的東西。所有行號對應 base commit。

## 1. 可移植模式

### 1.1 單一 PreviewController + WKWebView re-hosting

`App/Views/WorkspaceWindow.swift:104-186`（`EditorWorkspace`）：`@StateObject PreviewController`
在 view 出現期間建立一次，`PreviewPane` 透過 `MarkdownPreviewWebView`（NSViewRepresentable）
掛載。`PreviewWebHostView.attach(webView:)`（`Packages/PreviewKit/.../MarkdownPreviewWebView.swift:42-52`）
的模式正是「同一 instance 換容器」：`removeFromSuperview()` 後 `addSubview` 同一個
`WKWebView`，不重建、不 reload page。

**iOS 對應：** 07 lane 會新增 `UIViewRepresentable` 版本（見 handoff 07「Layout mode 變更只
重新 attach 同一 web view」）。10 的 container 對 editor／preview 都做同一件事：layout
切換只改 attach target 或可見性，不 unmount。

### 1.2 Editor hosting 以 opaque identity 識別文件

`MarkdownEditorView`（NSViewRepresentable）的參數有 `documentIdentity:
EditorDocumentIdentity?`、`documentBindingID: EditorDocumentBindingID?`
（`Packages/EditorKit/.../MarkdownEditorView.swift:32-58`），配合
`AppState+EditorBinding.swift` 的 binding installation registry（`install`/`revoke`/
writer activation with `baseSnapshot.revision` guard）：App 不靠 SwiftUI view identity
判斷「這是哪份文件的 editor」，而是靠 opaque token + revision。

**iOS 對應：** contracts.md §2 的 `IOSDocumentIdentity`／`IOSDocumentRevision`／
`selectionGeneration`／`accessGeneration` 是同一概念在 iOS contract 上的凍結版。10 的
scene state 持有的是 `IOSDocumentIdentity`（不是 URL、不是 index）；任何「current editor」
的斷言都以 identity 比對，不允許 A→B→A 被錯認（contracts.md §2 generation 語意）。

### 1.3 高頻 publish 去重：MenuBarState

`App/MenuBarState.swift`：menu enablement 不直接觀察 `AppState`（keystroke 級別的
objectWillChange 會 thrash NSMenu），而是把 menu 需要的少數欄位收成 `Equatable`
`MenuBarSnapshot`，在 post-mutation 時機重讀、只在真的變時 republish。

**iOS 對應：** shell chrome（title／dirty dot／saving spinner／banner／toolbar enablement）
同理需要一個 deduplicated `IOSShellChromeSnapshot: Equatable`——觀察 05 `IOSDocumentEvent`／
editor snapshot 的派生值，而不是每次 publish 都 rebuild toolbar。**這是 lane-10 內部
view-model 設計，不是新契約。**

### 1.4 per-scene 而非 app-global 的 UI 狀態

macOS 目前 `WindowGroup` 共享一個 App-scoped `AppState`（agent.md §5 已知限制），但
per-window 狀態的先例存在：`EditorFindHost.chromeFocusByWindow: [Int: …]` 以 window
number 為 key（`App/EditorFindHost.swift:36-44`）、`WindowKeyStateTracker` 以 keyEpoch
跟隨 window attach/detach（`App/Views/WindowKeyStateTracker.swift`）。

**iOS 對應：** handoff 10 明定「scene 首版單一；未來可分 scene 的狀態由 13 分配，不能
App-scoped 全域存 active selection／writer」。lane-10 設計因此把 *所有* per-scene 狀態
（navigation、presentation、focus、current editor facade）收進一個 scene 建立時產生的
`IOSShellSceneState`，經 `EnvironmentObject` 下傳；沒有任何 singleton／static「目前
editor」。

### 1.5 Banner／status chrome 的委派模式

`EditorWorkspace`（`WorkspaceWindow.swift:118-134`）依序疊加 recovery／reconciliation／
missing-file／external-change banner；按鈕動作一律 `appState.*()` 委派——view 只有
狀態投影與觸發，沒有政策。

**iOS 對應：** `IOSDocumentState`（opening／ready／saving／conflict／unavailable／closed，
contracts.md §5）驅動同位置的 banner 區；動作（Reload／Keep mine／Save copy／重新選擇
權限）全部委派 13 state facade，shell 不決策。

## 2. 不可移植的部分

### 2.1 Responder-chain command routing → 換成 scene-scoped router

macOS 的 Format／Find 命令走 `NSApp.sendAction` responder chain
（`EditorCommandDispatcher`，`EditingBehaviorsSupport.swift:59-108`；
`EditorFindCommandDispatcher`，`EditorFindCommandDispatcher.swift:24-50`）：menu action
丟進 chain，focused editor 上的 `STTextView` selector 接住。

iOS 沒有等價的 app-level responder menu；handoff 規定「命令只作用到該 scene 的有效
editor，不重導到未聚焦文件」。**設計（見 shell-design.md §3）：** scene 建立的
`IOSShellActionRouter` 持有 *該 scene* current editor facade；toolbar 按鈕與
UIKeyCommand 都打到 router，router 只做「拿到哪個 facade → 轉 08 handler」，
不持有 mutation 能力本身。這保留了 macOS 的「no-ops instead of falling back to
another editor」語意。

### 2.2 `EditorLayoutMode` cycle → 換成 geometry-driven layout policy

Mac 的 `EditorLayoutMode`（sourcePreview／sourceOnly／wysiwyg，`App/EditorLayoutMode.swift`）
是使用者手動循環的 *偏好*；iOS 的規則是 *環境推導*：compact→切換、regular 且內容區
≥900 pt→並排、內容區 <900 pt→切換，「以實際可用 content width 為準，不只看裝置型號」。
WYSIWYG 也不在 iOS 首版邊界。**需要新的純函數 layout policy**（lane-10 owned，不需契約）。

### 2.3 `NavigationSplitView` 的取捨

Mac R17 以 `HStack` + fixed 280pt sidebar（`WorkspaceWindow.swift:18-33`）。iOS：
compact 用 `NavigationStack`（files list → push document screen）；regular 用
`NavigationSplitView`（sidebar=files／detail=document）。**關鍵：** 900 pt 判定的
content width 是 *detail column* 的寬度（sidebar 佔用後剩餘），不是整個 window／device。
iPad 開 sidebar 或 Split View 半屏時 detail 可能 <900 pt 而應落回切換式。

### 2.4 Scroll sync 不在首版範圍

macOS 有 `EditorPreviewScrollCoordinator`（typewriter sync，`App/Views/EditorScrollBridge.swift`）。
Handoff 10 的 UX 清單只要求「keyboard／selection／scroll／undo 不因 orientation 或模式
切換而重置」——scroll *保留*，沒有 editor↔preview *同步*。**列為不在 lane-10 首版；
若 11 validation 要求同步，是額外 proposal。**（保留此判斷供 13 review。）

## 3. iOS 必須新增、macOS 沒有對應物的

| 需要 | 原因 | 層級 |
|---|---|---|
| `IOSContentLayout` 純 policy（width→toggle/sideBySide） | macOS 是 manual cycle | lane-10 內部 |
| `IOSShellActionRouter`（scene-scoped） | iOS 無 app responder chain；08 只給 descriptors，10 負責安裝＋路由 | lane-10 內部 |
| `IOSShellSceneState`（scene 的 navigation／presentation／focus／facade 綁定） | 不能 app-global | lane-10 內部，13 注入 services |
| `IOSShellPresentation`（sheet 列舉：frontmatter／find／imagePicker） | macOS 用 panel／inspector | lane-10 內部 |
| Compact editor/preview segmented toggle | iPhone 無並排空間 | lane-10 內部 |
| Overflow menu（toolbar 項目超過可達寬度時） | handoff a11y 要求 | lane-10 內部 |

## 4. Provider 接點現況（全部 pending，以 doubles 驗證）

| Shell 消費 | Owner | C0 狀態 |
|---|---|---|
| `IOSSourceEditorControlling`（captureSnapshot／apply／reveal／undo／redo） | 04 | contracts.md §2 prose；Swift declaration 待 C0 |
| Editor hosted view（SwiftUI mountable） | 04 | 名稱未定 → wiring request |
| `IOSDocumentStore`／`IOSDocumentState`／`IOSDocumentEvent` | 05 | contracts.md §5；「13 在 C0 為這些能力落實唯一 Swift declaration」 |
| `IOSWorkspaceAccessProviding`／`IOSWorkspaceSnapshot` | 06／03 | contracts.md §4 |
| Preview iOS hosted view | 07 | 名稱未定 → wiring request |
| `IOSAuthoringAction` descriptors＋handlers＋hosted views | 08 | contracts.md §7；consumer seam 待 C0 |
| Image picker hosted flow | 09 | contracts.md §7 |
| Scene state facade（open／new／save-as／document registry） | 13 | 未定義 → wiring request |

## 5. 調查結論

- Handoff 的所有固定 UX 都可以用「mounted-once 雙容器 + scene-scoped router + 純
  layout policy」達成，不需要觸碰 source／儲存／composition 政策。
- 最大的契約缺口不在 provider 實作，而在 **13 的 scene state facade 與各 hosted view
  的 consumer-facing 名稱**——這些若不進 C0 凍結，lane-10 只能發明（被禁止）。見
  `wiring-requests.md`。
- 測試可全以 protocol doubles 進行（見 `test-plan.md`）；identity-retention 斷言依賴的
  是 container 行為而非 provider 真身，先行可驗證。
