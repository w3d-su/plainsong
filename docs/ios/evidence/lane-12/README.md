# Lane 12 — iOS 建置、CI 與 unsigned IPA：交付摘要

日期：2026-10-08。契約版本：IOS-C0-v1（specification，尚未實作）。

## 狀態宣告

**C0 尚未交付。** `docs/ios/integration-ledger.md` 記錄 `IOS_BASE_REF`／`IOS_BASE_SHA`
為 *Not published*，repo 內無 `phase3-ios-integration` 分支、無 `AppIOS/`、無 iOS
package manifests。依 handoff「C0 前先設計 toolchain preflight／腳本／workflow；
C0 與 13→12 檔案交接後才寫正式全域檔案」，本交付為 **來源調查＋設計＋可語法驗證的
draft 腳本**；全域檔案未動，等待 13 的明確交接 commit。

## 交付格式

| 項目 | 值 |
|---|---|
| Branch | `phase3-ios-build-and-ipa` |
| Worktree | `/private/tmp/plainsong-ios-build-and-ipa` |
| Base SHA | `2144c46`（`phase3-ios-parallel-handoffs` head = snapshot `b13aa62`＋packet）。**調查基準，非 IOS_BASE_SHA**；公布後實作 worktree 以該 SHA 重建，本證據於 owned path 平移 |
| Head SHA | branch tip（`git rev-parse phase3-ios-build-and-ipa`） |
| PR | **未開。** packet 未 merge 進 `main`，現在開 PR 會把 13 的 packet 檔案混進 diff；IOS_BASE_REF 公布後依共同基準開可審查 PR |
| 實際修改路徑 | `docs/ios/evidence/lane-12/**`、`docs/ios/handoffs/12-build-and-ipa.md`（Evidence 段） |
| 已實作介面 | 無——全域檔案所有權尚未移交 |
| Named tests | 未執行（無 iOS target）；負向測試計畫見 test-plan.md |
| 已跑的檢查 | `bash -n` ×6 draft scripts、`py_compile` resource preflight、`xcodegen generate`、toolchain inventory（toolchain-preflight.md） |
| 未跑的檢查 | ios-build/test/archive/ipa 實跑、ios.yml lint、Mac `make build/test`（本 lane 未改任何全域檔，Mac 行為無變化）——未跑即未跑 |

## 文件索引

- [`toolchain-preflight.md`](toolchain-preflight.md) — 本機實測 inventory＋preflight gate 設計；
  **關鍵發現：Xcode 27β 只有 iOS 27.0 SDK（≥26 可編譯 deployment 26），且零 iOS simulator runtime**。
- [`build-design.md`](build-design.md) — 四個固定入口、Scripts/ios 版面、固定鎖、
  unsigned 語意、metadata schema、ios.yml／project.yml 增量設計。
- [`test-plan.md`](test-plan.md) — 已跑檢查、負向測試 N1–N12、三類關卡分列格式。
- [`wiring-requests.md`](wiring-requests.md) — 需要 13 在 C0 凍結／確認的 14 項（交接 commit、
  target/bundle 命名、11 manifest 介面、gitignore、SDK 語意、runner image）。
- [`drafts/`](drafts/) — 完整 draft 腳本（lock wrapper、preflight、四個 runner、resource
  preflight、ios.yml、Makefile/project.yml snippet），交接後平移到全域路徑。

## 關卡分列

- **已關閉：** 無（設計階段不關產品關卡）。
- **待整合／待交接：** 13 C0＋13→12 全域檔案交接 commit；C0 target/product 名稱；
  11 required-resources manifest；iOS simulator runtime 安裝（環境）。
- **Owner-only：** unsigned IPA 交付僅 **BUILD PASS / INSTALL OPEN**——owner 重簽、
  真機安裝啟動、Files 讀寫皆 OPEN，lane-12 不關。

## 不做的事（依 handoff 邊界）

- 未改 `project.yml`／`Makefile`／`Scripts/`／`.github/workflows/ci.yml`／`App/**`／
  package manifests／`agent.md`／Decision Log／integration ledger／其他 lane 路徑。
- 不產生簽名、不保存 credentials／provisioning、不發布 IPA、不自行 merge、不 force-push、
  不改 owner checkout 或其他 worktree。
