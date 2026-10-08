# Lane 10 Shell 設計 — 視圖結構、routing、不變條件

契約版本 IOS-C0-v1（specification）。以下 Swift 型別名稱是 lane-10 內部設計提案；
斜體 *名稱* 表示需由 C0 凍結的 consumer-facing 名稱（見 `wiring-requests.md`），
lane-10 不自行定義它們。

## 1. View tree（提案）

```
Scene（13-owned：app entry + scene factory + services facade）
└── IOSShellRootView                        [10]
    │  @StateObject scene: IOSShellSceneState     ← 每 scene 一個，13 注入 *IOSSceneServices*
    │  @StateObject router: IOSShellActionRouter  ← scene-scoped
    ├── compact：NavigationStack(path: scene.route)
    │     ├── IOSWorkspaceBrowserView         [10, Navigation/]
    │     └── IOSDocumentScreen               [10]
    └── regular：NavigationSplitView
          ├── sidebar：IOSWorkspaceBrowserView
          └── detail：IOSDocumentScreen

IOSDocumentScreen
├── IOSDocumentStatusChrome                 標題／dirty dot／saving／conflict／unavailable
│   └── IOSDocumentBanner 區                banner 動作 → facade（Reload／Keep mine／Save copy）
├── IOSEditorPreviewContainer               ← 本 lane 的核心不變條件（§2）
│   ├── *EditorView*（04）                   mounted once per document attach
│   └── *PreviewView*（07）                  same WKWebView，re-parent only
├── IOSAuthoringToolbar                     bottom keyboard accessory + nav-bar toolbar
│   └── 項目來自 IOSAuthoringAction descriptors（08），經 router.perform
└── .sheet(item: scene.presentation)         frontmatter／find（08 hosted view）／imagePicker（09）
```

## 2. 核心不變條件：同一 editor、同一 preview instance

`IOSEditorPreviewContainer` **同時掛載** editor 與 preview 兩個 child；`IOSContentLayout`
只改兩者的 *可見性與幾何*（compact toggle 顯示其一；sideBySide 都顯示），從不做條件式
mount。具體方式：

- toggle mode：兩者皆在 hierarchy，未選中的以 `frame(width:0)`／`opacity(0)`＋
  `.accessibilityHidden(true)` 隱藏（a11y 不可達），或兩者各經 host-view 重新 attach
  到同一 slot——**re-parent 同一 UIView instance 合法**（先例：`PreviewWebHostView.attach`，
  `MarkdownPreviewWebView.swift:42-52`）。
- sideBySide：HStack 各半；寬度變化只改 frame。
- 文件切換（identity 變更）才換 attach target，且走 13 的 attach/detach 順序
  （generation 提升→取消 pending→attach 新文件，contracts.md §13）。

**為何不是單 container 重 attach：** 兩案都滿足 instance 保留；雙掛載在 toggle 時零
re-parent cost，且 preview 持續 render，切回即為最新。記憶體代價是一個常駐
WKWebView——macOS 行為相同（preview hidden 時 controller 仍存活）。若 11 效能門檻要求
hidden-preview 暫停 render，可在 container 加 `renderingPaused` 控制而不改 identity
不變條件。

**失敗反例（設計要排除的）：**

1. `if mode == .editor { EditorView() } else { PreviewView() }` — SwiftUI 銷毀未走分支：
   WKWebView reload、UITextView 丟 marked text／Undo。`testShellUsesSingleEditorAndPreview…`
   的 detach counter 專門抓這個。
2. 在 `onChange(of: sizeClass)` 裡重建 representable — 同上，只是隱性。
3. 900 pt 邊界 live-resize 抖動 — 雙掛載使 mode flip 只是 visibility 改變，
   **不需要** hysteresis；若當初採 re-parent 單槽案就需要，這是雙掛載案的決定性優點。
4. 隱藏 view 留在 a11y tree — VoiceOver 摸到看不見的 editor；必須
   `.accessibilityHidden`。

## 3. Scene-scoped action routing

```
IOSShellActionRouter（@MainActor，final class，ObservableObject）
  - services: *IOSSceneServices*（13 facade；open/new/save-as/document state）
  - editorFacade: (any IOSSourceEditorControlling)?   ← scene current editor attach 後綁定
  - documentID: IOSDocumentIdentity?                  ← 綁定時的 identity
  - actionHandlers: [IOSAuthoringAction: (context) -> Void]  ← 08 vend
  - presentation: IOSShellPresentation                 ← sheet 狀態
  perform(_ action: IOSAuthoringAction)
  performUndo() / performRedo()                        ← 直接轉 facade.undo()/.redo()
```

規則：

- `perform` 把 *本 scene 當下綁定的 facade* 傳給 08 的 handler；handler 依契約走
  `captureSnapshot() → plan → apply(IOSAuthorizedEdit)`。**Router 不產生 edit、
  不碰 source、不持有 DocumentSession。**
- facade 為 nil（無文件／未 attach）→ 該 action disabled（toolbar）或 no-op（鍵盤），
  不 fallback 到別的 scene／文件（同 macOS「不重導」語意）。
- enablement 由最近一次 capture 的 snapshot 派生（`canWrite`、marked text、conflict
  狀態經 `IOSDocumentState`）；executor 端最終仍重驗——UI disable 只是 UX，不是
  安全機制（contracts.md §7「不能先改 source」由 04 executor 保證）。
- Undo/Redo 屬 04 的 native dispatch；shell 只安裝 UI 命令到 router，不自攔。
- 鍵盤：`.keyboardShortcut`（SwiftUI，iPadOS 15+；iOS 26 下可配合 commands modifier）＋
  hardware keyboard 的 UIKeyCommand 發現。descriptor 的快捷鍵語義沿用 repo 既有
  （⌘B/⌘I/⌘K/⌘0–6/⌘⇧Q/⌘⇧K/⌘L/⌥⌘F/⌘F/⌘G/⌘E…），由 08 descriptor 給出，shell
  只安裝到 router。

**失敗反例：**

1. Singleton／NotificationCenter「active editor」— 兩個 scene 時命令落進背景 scene 的
   文件。Router 在 scene 建立時產生、EnvironmentObject 下傳，結構上不可能跨 scene。
2. Router 在 bind 時 capture facade 強引用後不再更新 — document 切換後 format 打進
   舊文件。**對策：** 每次 `perform` 重新讀 `scene.currentEditor`（且 04 executor 以
   documentID＋generations 雙重拒絕，縱使 UI 競態也被 executor 擋下）。
3. Read-only／conflict 時送出 edit — 雙保險：toolbar 依 snapshot disable；fake executor
   回 `.refused(.readOnly)` 時 UI 顯示狀態而非靜默吞掉。
   `testToolbarUsesCurrentSceneEditorAndRefusesReadOnlyDocument` 驗證兩層。

## 4. Layout policy（純、可測）

```swift
enum IOSContentLayout: Equatable {
    case toggle(segment: EditorOrPreview)   // compact 或 width<900：分頁切換
    case sideBySide                         // regular 且 contentWidth ≥ 900
}

func iosContentLayout(
    prefersRegularWidth: Bool,              // horizontalSizeClass == .regular
    contentWidth: CGFloat                   // document pane 實際寬（非 device／window）
) -> IOSContentLayout
```

- `contentWidth` 取自 document screen 的 geometry（`GeometryReader`／`onGeometryChange`），
  **扣除 sidebar 後的 detail 寬**。iPad Split View／Stage Manager 縮窗自然落入正確分支。
- 邊界含 900 本身 → sideBySide（handoff：「小於 900 pt 改用切換」）。
- Compact 預設 segment = source；使用者切 preview 為 per-scene 偏好（`scene` state），
  不持久化（首版無偏好持久化需求）。

## 5. Navigation／files／status chrome

- `IOSWorkspaceBrowserView`：消費 13 facade 提供的 `IOSWorkspaceSnapshot`（generation
  標記的 immutable tree；entries 有 opaque ID、relativePath、kind、availability）。
  點檔案 → `scene.open(location)` 委派 facade；不直接碰 `IOSWorkspaceAccessProviding`
  （那是 06 的 provider API，facade 屏蔽 grant 細節——見 wiring-requests §2）。
- 無 workspace（single file）時 browser 顯示 recents／open 入口；grant 失效
  →「重新選擇」狀態委派 facade。
- `IOSDocumentStatusChrome`：檔名＋dirty dot（macOS DocumentHeader 對應）、
  saving indicator、`IOSDocumentState` 的 conflict／unavailable banner。
  全部唯讀渲染＋委派。
- 「開啟／新建／另存」按鈕 → facade 對應方法（facade 內部走 06 picker／05 store）。

## 6. Sheets 與「cancel ≠ commit」

- `IOSShellPresentation: Hashable`：`none`／`frontmatter`／`find`／`replace`／`imagePicker`。
  以 `.sheet(item:)` 呈現；hosted view 由 08／09 vend（名稱待 C0）。
- Dismiss 只設 `presentation = .none`——**不發任何 commit／apply**。08／09 的 flow
  自己處理 pending proposal 的放棄與（image 的）rollback；shell 的責任只有「不代替
  使用者確認」。
- Document switch 時 dismiss 所有 sheet：pending capture 綁舊 identity，留著只會被
  executor 拒絕且 UX 誤導。
- 失敗反例：sheet `onDismiss` 裡 flush pending edit —— 正是
  `testDismissedSheetDoesNotCommitPendingEdit` 要抓的；設計上 shell 完全不持有
  proposal 物件，想 flush 也沒有東西可 flush。

## 7. Accessibility（首版內建，非補丁）

- 所有 chrome 元素 VoiceOver label＋hint（dirty=「已修改」、saving=「儲存中」）；
  `.accessibilityIdentifier` 命名沿用 `plainsong.*` 前綴。
- 觸控 target ≥44×44 pt；Dynamic Type 支援（SF font styles，不固定點數）。
- Toolbar 溢出 → 收進「更多」menu（不壓縮 icon）；menu 項目保留完整 label。
- 鍵盤焦點可達：toolbar items 可 focus、有 discoverability title；
  segmented Source/Preview 可鍵盤操作。
- 隱藏 pane `.accessibilityHidden(true)`（§2）。

## 8. Shell 明確不做

- 不建立 grant／lease，不碰 `IOSWorkspaceAccessProviding` 內部。
- 不調用 `DocumentSession`／不寫 source；不持有 shadow editable String。
- 不決定儲存時機、衝突政策、composition；不持久化任何狀態（recents 屬 06）。
- 不為測試加 mutation bypass——view 需要 bypass 才能測是 stop condition（handoff §驗收）。
