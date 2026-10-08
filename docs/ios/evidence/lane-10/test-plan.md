# Lane 10 測試計畫 — named acceptance tests、doubles、negative probes

目標 target：`AppIOSTests`（C0 建立 hosted test target；lane-10 tests 歸
`AppIOSTests/Shell/**`）。測試型別名為提案；frozen protocol 簽名以 C0 為準。

## 1. Test doubles（僅 test support；不成為 production provider）

| Double | 內容 |
|---|---|
| `FakeSourceEditor` | 實作 `IOSSourceEditorControlling`：記錄 `captureSnapshot`／`apply`／`reveal`／`undo`／`redo` 呼叫序列；可設定 snapshot（`canWrite`、`hasMarkedText`、selection/access generation、revision）；`apply` 回傳可編程 `IOSEditOutcome`；`appliedEdits` 陣列供斷言 |
| `FakeNativeHostView` | 普通 `UIView` 子類，記錄 `willMove`/`didMoveToWindow`/`removeFromSuperview` 次數與 `ObjectIdentifier`；扮演 04／07 hosted view 的「native 身分」替身——**測的是 container 的 attach 行為，不是 provider 本身** |
| `FakeEditorView`／`FakePreviewView` | `UIViewRepresentable` 包 `FakeNativeHostView`；fake preview 以 plain view 代替 WKWebView（單元測試不建真 WebKit；真 WKWebView retain 留給 simulator smoke） |
| `FakeAuthoringSource` | vend 固定 `IOSAuthoringAction` descriptor 清單＋handlers；記錄每個 handler 收到的 editor facade `ObjectIdentifier` 與 action |
| `FakeSceneServices` | 13 facade 替身：document state `AsyncStream`（可注入 opening→ready→saving→conflict 序列）、`open/new/saveAs/resolveExternal` 呼叫 log、fake workspace snapshot publisher |
| `FakeHostedSheet` | 08／09 hosted view 替身：`onCommit`／`onCancel` 記錄器＋「pending proposal」標記物——若在 dismiss 路徑被 commit，tripwire 讓測試直接失敗 |
| `RecordingImageFlow` | 09 flow 替身：記錄 staged-asset 的 `commit`／`rollback` token 消費次數 |

## 2. Named acceptance tests

### 2.1 `testShellUsesSingleEditorAndPreviewAcrossLayoutChanges`

- 掛 `IOSEditorPreviewContainer` + fake editor/preview；以測試 driver 依序送 layout
  參數：compact → regular 1200 pt → regular 800 pt → compact → …（≥20 次往返，含
  899→900→901 邊界掃過）。
- 斷言：兩個 `FakeNativeHostView` 的 `ObjectIdentifier` 全程不變；
  `removeFromSuperview` 計數為 0（雙掛載案）；`didMoveToWindow` ≤ 1；
  hidden 期間 `accessibilityHidden == true`；`sideBySide` 時兩者皆可見。
- **Negative probe：** 把 container 換成「每個 layout 重建 child」的病態實作——
  detach counter >0 → 測試失敗，證明斷言真的在量 identity。

### 2.2 `testLayoutTransitionRetainsSelectionScrollAndUndo`

- fake editor 狀態：selection `{42,8}`、contentOffset y=1337、undoDepth=3、
  `hasMarkedText=true`。
- 跑 2.1 全部 transitions＋模擬 rotation（同 policy 函數餵不同 size class/geometry）。
- 斷言：四項狀態逐一相等；layout 路徑對 facade 的 mutation 方法呼叫數 = 0；
  `DocumentSnapshot`／source 無任何寫入嘗試記錄。
- 界線說明：此測試證明 *shell* 不重置；「真 UITextView 經 re-parent／容器變更後
  native Undo stack 與 marked text 存活」屬 04 的 device gate（真機注音 Undo 由
  01 M0＋11 驗收，shell 不以 fake 宣稱）。

### 2.3 `testToolbarUsesCurrentSceneEditorAndRefusesReadOnlyDocument`

- 建兩個獨立 `IOSShellActionRouter`，各綁 `FakeSourceEditor` A／B。
- router A `perform(.bold)`（名稱以 08 descriptor 為準）→ 斷言：A 的
  handler 收到 facade A；B 的呼叫 log 為空；A handler 內的 `apply` 目標 = A。
- A 的 snapshot 設 `canWrite=false`（模擬 read-only）→ toolbar enablement false；
  若仍強行 dispatch → fake `apply` 回 `.refused(.readOnly)`：斷言零 mutation、
  refusal 有回饋路徑（shell 顯示唯讀狀態，不靜默）。
- 另設 conflict 狀態（`IOSDocumentState` → conflict）→ 同 2.3 斷言。
- router 無 facade（無文件）→ `perform` no-op，不 crash、不 cross-route。

### 2.4 `testDismissedSheetDoesNotCommitPendingEdit`

- 呈現 `FakeHostedSheet`（frontmatter 型）：內含已 capture 的 proposal（base rev 7、
  舊 generations）→ 使用者取消 → `presentation = .none`。
- 斷言：`FakeSourceEditor.apply` 計數 = 0；sheet teardown 未觸發 commit；
  tripwire 未啟動。
- 變體（image）：`RecordingImageFlow` staged→cancel → `rollback` token 恰消費一次、
  `commit` 零次、editor 無呼叫。
- **Negative probe：** 在 dismiss handler 偷偷 flush proposal 的病態 sheet →
  tripwire 觸發，測試失敗。

### 2.5 邊界／resizing smoke（module 內可做＋sim 待跑分列）

- 純函數：`iosContentLayout` 的真值表——{regular,compact} × {899,900,901} pt →
  預期 mode；900 含於 sideBySide。
- mounted-view 邊界：geometry 在 899↔901 來回 → 同 2.1 identity 斷言。
- **列為未跑（待 simulator／device）：** iPhone／iPad 直橫向真實 rotation、
  Split View 拖動經過 900 pt、外接鍵盤、composing 中切換、VoiceOver——
  11／owner gates，fake 不宣稱通過。

## 3. 覆蓋矩陣（設計不變條件 → 測試）

| 不變條件 | 測試 |
|---|---|
| 同一 editor／preview instance | 2.1, 2.5 |
| selection／scroll／undo／composing 不因 layout 重置 | 2.2 |
| 命令只到本 scene 的 current editor | 2.3 |
| read-only／conflict 不發寫入且可見 | 2.3 |
| sheet cancel 不 commit | 2.4 |
| 900 pt 以 content width 判定 | 2.5 純函數＋mounted |

## 4. 與其他 lane 的驗收切分

- 以上全部以 doubles 驗 *shell 的容器／路由／呈現* 責任。
- 真實 provider 接上後的 hosted 驗證（04 editor＋07 preview＋08 descriptors 經 router）
  屬整合：13 composition 後 11 驗收，lane-10 提供 wiring map（`shell-design.md`）。
- 真機 IME／Undo／VoiceOver／外接鍵盤／Split View：owner／11 清單，不列入本 lane
  fake 結果。
