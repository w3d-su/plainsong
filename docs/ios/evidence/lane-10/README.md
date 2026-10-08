# Lane 10 — iPhone／iPad 自適應 App shell：交付摘要

日期：2026-10-08。契約版本：IOS-C0-v1（specification，尚未實作）。

## 狀態宣告

**C0 尚未交付。** `docs/ios/integration-ledger.md` 目前記錄 `IOS_BASE_REF`／`IOS_BASE_SHA`
為 *Not published*，lane 13 尚無 `phase3-ios-integration` 分支或 C0 commit；repo 內不存在
`AppIOS/`、`AppIOSTests/`、EditorKitIOS／WorkspaceKitIOS 或任何已凍結的 Swift contract
declaration。依 handoff 規則，本交付只做**來源調查與測試設計**，沒有、也不得發明平行 API
或自行從 `main` 建立另一份 contracts。

## 交付格式

| 項目 | 值 |
|---|---|
| Branch | `phase3-ios-adaptive-shell` |
| Base SHA | `2144c46`（`phase3-ios-parallel-handoffs` head：source snapshot `b13aa620c7444f2ccd3a8fe3a5b8b0afe0e997b2` + handoff packet commit）。**這是調查基準，不是 IOS_BASE_SHA**；IOS_BASE_SHA 公布後，實作 worktree 以該 SHA 重建，本證據檔於 owned path 平移 |
| Head SHA | branch tip（本檔所在的最新 commit；以 `git rev-parse phase3-ios-adaptive-shell` 為準，已 push 至 origin） |
| PR | **未開。** C0 未公布、packet 未 merge 進 `main`，現在以任何 base 開 PR 都會把 13 的 packet 檔案混進 lane-10 diff。待 IOS_BASE_REF 公布後依共同基準開可審查 PR |
| 實際修改路徑 | `docs/ios/evidence/lane-10/**`（本目錄，lane-10 exclusive） |
| 已實作介面 | 無 — 凍結介面尚無可編譯宣告 |
| 仍使用 doubles 的接點 | 全部 provider 接點（04／05／06／07／08／09／13） |
| Named tests | 未執行：測試設計完成（見 `test-plan.md`），等 C0 scaffold 後以 hosted test target 落實 |
| 未跑的檢查 | Swift build／tests／lint／simulator（無 AppIOS target 可建）；未跑即未跑 |

## 文件索引

- [`source-investigation.md`](source-investigation.md) — macOS shell 現況盤點，逐條映射到 iOS 設計輸入。
- [`shell-design.md`](shell-design.md) — lane-10 視圖結構、scene-scoped action routing、layout policy、不變條件與失敗反例。
- [`test-plan.md`](test-plan.md) — 五個 named acceptance tests 的 fake 設計、斷言與 negative probes。
- [`wiring-requests.md`](wiring-requests.md) — 需要 13 在 C0 凍結／提供的最小 wiring；不交給 13 就得自行發明的項目清單。

## 關卡分列

- **已關閉：** 無（調查階段不關產品關卡）。
- **待整合：** C0 契約凍結（`IOSSourceEditorControlling`、`IOSDocumentStore`、workspace
  access provider、`IOSAuthoringAction` consumer seam、scene state facade、hosted view
  names）、`AppIOS` skeleton 與 `AppIOSTests` hosted test target 註冊、04–09 真實 providers、
  13 production composition。
- **Owner-only 真機：** 橫直向切換中的中文 composing、外接鍵盤 command discovery、
  VoiceOver、Dynamic Type、iPad Split View／Stage Manager resizing、真機 Undo retention。

## 不做的事（依 handoff 邊界）

- 不改 `AppIOS/App/**`、`State/**`、`Composition/**`，不自建第二個 AppState。
- 不改任何 package／contract／manifest、Mac `App/**`、`project.yml`、Makefile、CI、
  `agent.md`、Decision Log、其他 lane 的路徑。
- 不 merge 自己的 PR，不 force-push，不改 owner checkout 或其他 worktree。
