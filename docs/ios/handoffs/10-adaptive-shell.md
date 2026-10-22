# 10 — iPhone／iPad 自適應 App shell

## 任務與智力

**L3 高。** 能處理 SwiftUI view lifetime、UIKit hosting、鍵盤焦點、視窗縮放及 accessibility；UI 切換必須保留 editor／preview instance，不能因為 view reconstruction 丟 Undo／組字。儲存／authority／composition policy 變更交給 13 的 L4。

分支：`phase3-ios-adaptive-shell`。先讀 repository `agent.md`、[總入口](../README.md)、[IOS-C0-v1](../contracts.md)。工作目標是可用 fake services 展示／驗證的 UI，production factory 接線屬 13。

## 開工、依賴與範圍

- C0 後即可完成 views、navigation 與 tests。使用 frozen interfaces，fake implementation 只放本線 test／preview support。
- 實際 provider：04 editor、05 document store、06 workspace/access、07 preview、08 authoring、09 images；production 接線還要 01 M0 owner 關卡。
- 擁有：`AppIOS/UI/**`、`AppIOS/Navigation/**`、`AppIOSTests/Shell/**`、`docs/ios/evidence/lane-10/**`。
- 不修改：`AppIOS/App/**`、`State/**`、`Composition/**`；任何 package／contract／manifest；其他 Features；Mac `App/**`；`project.yml`、Makefile、CI、`agent.md`、Decision Log。
- C0 的 scaffolding 不完整時向 13 提供最小 wiring request；不能自己新增第二個 AppState 或模擬保存成功。

## 固定 UX

- iPhone／compact width：檔案導覽 + 原始碼／預覽切換。iPad regular width 且內容區可容納兩欄時並排；內容區小於 900 pt 改用切換，以實際可用 content width 為準，不只看裝置型號。
- 保留一個 current editor 與一個 WKWebView；布局切換只改容器／可見性，不 detach 重建。keyboard／selection／scroll／undo 不因 orientation 或模式切換而重置。
- SwiftUI navigation 顯示 Files 工作區、目前文件、dirty/save/conflict/unavailable 狀態；開啟／新建／另存操作委派給 13 的 state facade。
- 底部鍵盤工具列與 toolbar 消費 08 的 IOSAuthoringAction；08 決定 action descriptors，04 擁有 typing 與 Undo／Redo。命令只作用到該 scene 的有效 editor，不重導到未聚焦文件。
- Frontmatter 與 Find／Replace 的 sheet／panel hosted view 來自 08；image picker hosted view 來自 09。cancel／dismiss 不代表完成寫入。
- scene 首版單一；未來可分 scene 的狀態由 13 分配，不能 App-scoped 全域存 active selection／writer。
- VoiceOver labels、可到達的鍵盤焦點、Dynamic Type、最少 44 pt 的可觸控 targets。工具列項目過多使用可達的 overflow menu，不壓縮成不可點圖示。

## 驗收

1. `testShellUsesSingleEditorAndPreviewAcrossLayoutChanges`：compact↔wide 重複切換，identity 不變。
2. `testLayoutTransitionRetainsSelectionScrollAndUndo`：不新增 source mutation；native undo history 不被重置。
3. `testToolbarUsesCurrentSceneEditorAndRefusesReadOnlyDocument`：fake facade 記錄唯一目的地，read-only／conflict 可見且不發寫入。
4. `testDismissedSheetDoesNotCommitPendingEdit`：取消 authoring／image 等待流程不產生 edit。
5. iPhone／iPad simulator 的橫直向／900 pt 邊界與 resizing smoke；真機外接鍵盤、中文 composing 中切換、VoiceOver 由 11／owner 驗收，不能以 fake 宣稱通過。

尚無 production providers 時，交付 mock-backed preview／tests 和 wiring map，不交付另一套持久化／編輯器。視圖為了測試而需要 mutation bypass 是 stop condition。

## PR 與 evidence

附 owned paths、head/base SHA、contract version、named tests、screenshots、視窗大小與 unresolved integration/manual gates。13 review state lifetime／command routing，Claude review UX 與不變量。沒有實際跑的場景列未驗證。

## 可直接貼給 agent

```text
請執行 docs/ios/handoffs/10-adaptive-shell.md（L3 高推理）。先讀 agent.md、docs/ios/README.md 與 docs/ios/contracts.md。從整合角色公布的 IOS_BASE_SHA 建立自己的 phase3-ios-adaptive-shell worktree。只修改 handoff 的 owned paths，完成 iPhone／iPad adaptive views 與 scene-scoped action routing，以 frozen interfaces 與 test doubles 驗證。保留同一 editor／preview instance，不修改 source／儲存／composition policy。不改共用檔案、不自行 merge，交付 PR／named tests／待整合與真機清單。C0 未公布前先做來源調查與案例，不發明平行 API。
```
