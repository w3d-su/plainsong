# 可直接貼給其他 agent 的啟動提示詞

先派 **13（C0／整合）** 和 **01（獨立 M0）**。13 公布可抓取的 IOS_BASE_REF、精確 IOS_BASE_SHA 與檔案交接後，其餘線依 frozen interfaces 同步開發。M0 不阻擋獨立模組／doubles 的開發；完整 App production 接線仍等待 M0 真機通過。

把 [總入口](README.md)、[共用契約](contracts.md)和該條 handoff 一起交給 agent。若 agent 不在同一台電腦，提供本文件包的 Git branch／PR 或上傳文件；不要只傳它無法存取的本機路徑。這些提示不授權 agent 發訊息到其他 chat、替 owner merge、操作簽名帳號或購買服務。

## 01 — M0 真機可行性｜L4 極高

[完整交接文件](handoffs/01-m0-device-spike.md)

```text
請執行 Plainsong iOS 的 01 M0 真機可行性 spike（L4 極高推理）。先讀 agent.md、docs/ios/README.md、docs/ios/contracts.md、docs/ios/handoffs/01-m0-device-spike.md。使用獨立 phase3-ios-m0-device-spike worktree，只寫 Prototypes/iOSM0 和自己的 evidence。這條線可在 C0 前開始，不修改正式 packages 或 App target。驗證 UIKit TextKit 2 中文 IME／Undo、Files／iCloud 文件與資料夾、背景儲存和未簽名 IPA 自行簽名後啟動。分列 simulator tests 與 owner 真機證據；硬體／簽名未提供時交付可重跑原型和 manual checklist，不假稱 PASS、不繼續完整 App 接線。遵守共享 Xcode 鎖，不自行 merge、force-push 或修改 owner checkout。
```

## 02 — 共用語法解析｜L4 極高

[完整交接文件](handoffs/02-syntax-kit.md)

```text
執行本 handoff 的 02，共用 SyntaxKit 抽取；最低 L4。先讀 docs/ios/README.md、contracts.md、agent.md，從 C0 契約凍結 commit 建獨立 worktree，分支 phase3-ios-syntax-kit。只改本文件允許路徑；維持 Mac tokens、fold/image region、樣式與 Replace 呈現守衛，純 API 回傳 semantic kind＋絕對 UTF-16 ranges。不可改全域 manifest 或契約。依當前 AGENTS.md 的 ctx7 規則查實用到的第三方 API；執行上述 differential 和 Mac regression，交付可審查 PR 與分開的 module／真機 gate 證據，不合併自己的 PR。
```

## 03 — 純工作區模型｜L3 高

[完整交接文件](handoffs/03-workspace-core.md)

```text
請執行 Plainsong iOS lane 03：WorkspaceCore，建議 L3 高階推理。
先完整讀 agent.md、docs/ios/README.md、docs/ios/contracts.md，及
docs/ios/handoffs/03-workspace-core.md；此 handoff 是你的執行規格。
確認 C0 已完成，從總表指定的最新 integration commit 建立 isolated worktree，
branch 為 phase3-ios-workspace-core。只修改本 handoff 的 exclusive paths。
抽取純檔案樹／byte-path 模型，保持 Mac mutationExpectation adapter 與 public API。
不得寫其他 lane／shared contracts／global files；需求交 integrator。
用 named tests 與 negative probes 證明 Unicode identity、generation、Mac proof 不變，
留下 base/head SHA、實際測試結果、manual open gates 與 Claude review evidence。
遵守 C0／M0 dependency gates；不自行 merge、force-push 或修改 owner checkout。
```

## 04 — 原生編輯器／IME／Undo｜L4 極高

[完整交接文件](handoffs/04-editor-kit-ios.md)

```text
執行本 handoff 的 04，最低 L4，分支 phase3-ios-editor-kit-ios。先讀 docs/ios/README.md、contracts.md、agent.md；只寫 EditorKitIOS 的 Editor／Presentation／tests／package manifest 與 lane-04 證據，Contracts.swift 由 C0 所有。用原生 UITextView＋TextKit 2，所有 authoring/image mutation 走 IOSSourceEditorControlling 與 IOSAuthorizedEdit，identity/revision/selection/access generation／native Undo／中文 IME 不可退步。02/05/13 未合併時用同契約 fake；M0 未通過只交付 module-ready。依 ctx7 規則驗證用到的 UIKit API，提供 deterministic stale/reconciliation/marked-text tests 與獨立真機待驗收表，不修改 Mac editor，不合併自己的 PR。
```

## 05 — 文件儲存／衝突／復原｜L4 極高

[完整交接文件](handoffs/05-document-io.md)

```text
請執行 Plainsong iOS lane 05：Document I/O，建議 L4 最高階推理。
先完整讀 agent.md、docs/ios/README.md、docs/ios/contracts.md，及
docs/ios/handoffs/05-document-io.md；此 handoff 是你的執行規格。
確認 C0 已完成，從總表指定的最新 integration commit 建立 isolated worktree，
branch 為 phase3-ios-document-io。只修改 Documents/Recovery 與自己的 tests。
以 UIDocument 實作 IOSDocumentStore、序列化 writer、baseline-only acknowledgement、
外部 conflict fence 與 durable recovery；不要寫 shared Package.swift/Contracts.swift。
先用 frozen doubles；06 真實 providers 與 01 M0 owner gates 通過後才產品接線。
不得以 markSaved 重寫晚於 save snapshot 的文字；失敗保留 draft 與 original。
提供可重現 races、negative probes、SHA/測試結果及真機 open gates給 Claude review。
不自行 merge、force-push 或修改 owner checkout；共享需求交 13 integrator。
```

## 06 — Files／授權／工作區｜L3 高，scope 接點 L4 review

[完整交接文件](handoffs/06-workspace-browser.md)

```text
請執行 Plainsong iOS lane 06：Workspace Browser/Access，建議 L3，lease 接點需 L4 review。
先完整讀 agent.md、docs/ios/README.md、docs/ios/contracts.md，及
docs/ios/handoffs/06-workspace-browser.md；此 handoff 是你的執行規格。
確認 C0 已完成，從總表指定的最新 integration commit 建立 isolated worktree，
branch 為 phase3-ios-workspace-browser。只修改 Access/Workspace 與自己的 tests。
實作 root-specific grants/leases、iOS bookmarks、recents(10)、coordinated snapshots、
provider resource reader 和 operation-owned staged image writer；不要寫 document source。
不改 shared Package.swift/Contracts.swift、App UI 或 PreviewKit policy。
先用 frozen doubles，01 M0 真機 gates 通過後才做完整 provider wiring。
提供 scope lifetime/generation/race tests、negative probes、provider matrix 與 SHA evidence，
交 Claude/L4 review；不自行 merge、force-push 或修改 owner checkout。
```

## 07 — 預覽與資源安全｜L4 極高

[完整交接文件](handoffs/07-preview-ios.md)

```text
請執行 Plainsong iOS lane 07：PreviewKit iOS，建議 L4 最高階推理。
先完整讀 agent.md、docs/ios/README.md、docs/ios/contracts.md，及
docs/ios/handoffs/07-preview-ios.md；此 handoff 是你的執行規格。
確認 C0 已完成，從總表指定的最新 integration commit 建立 isolated worktree，
branch 為 phase3-ios-preview-ios。只改 PreviewKit 允許路徑與自己的 tests。
保留 Mac 行為，加入 UIKit host/platform adapter、PreviewAssetReading 接點與 late-read fences。
不改 frozen contracts、bridge protocol、preview-src 或 committed JS bundle。
根目錄/token/grant generation、raster type/size/symlink/CSP checks 必須仍有效。
先用 mocks；06 providers 和 01 M0 gates 通過後才能產品接線。
驗證 stale reads、render/checkbox identity、Mac export regression與 iOS hosted tests，
留下 SHA、negative probes、manual/performance open gates 供 Claude/L4 review。
不自行 merge、force-push 或修改 owner checkout；共享需求交 13 integrator。
```

## 08 — 格式／Frontmatter／Find｜L3 高

[完整交接文件](handoffs/08-authoring-tools.md)

```text
執行本 handoff 的 08，最低 L3，分支 phase3-ios-authoring-tools。先讀 docs/ios/README.md、contracts.md、agent.md；只改 AppIOS/Features/Authoring、AppIOSTests/Authoring 與 lane-08 證據。重用 MarkdownCore；所有格式、Frontmatter 和單 Replace 都 capture 同一 editor snapshot，再由 IOSSourceEditorControlling apply IOSAuthorizedEdit，保留 identity/revision/selectionGeneration/accessGeneration。只提供 IOSAuthoringAction descriptors，10 安裝快捷鍵；不改 editor 或 session。以 private fake 可同步開發，保留 draft／query generation／UTF-16／拒絕零變更，完成 named tests 和 PR 證據；M0 真機 gate 未通過不能宣布 product-ready，不合併自己的 PR。
```

## 09 — 圖片交易式插入｜L4 極高

[完整交接文件](handoffs/09-image-insertion.md)

```text
執行本 handoff 的 09，最低 L4，分支 phase3-ios-image-insertion。先讀 docs/ios/README.md、contracts.md、agent.md；只寫 AppIOS/Features/Images、AppIOSTests/Images 與 lane-09 證據。使用 06 的 IOSWorkspaceAssetWriting→IOSStagedImageAsset，coordinated persistence／destination final validation 成功才可向 04 IOSSourceEditorControlling 提交 IOSAuthorizedEdit；同 document/revision/selectionGeneration/accessGeneration、可寫且非 composing 才接受。accepted 才 commit，其他 terminal path rollback／保留 recovery；Undo 不刪圖片。04/06 未完成可用 private 同契約 mock；依 ctx7 查實 PhotosUI/UIKit API，完成 deterministic stale／rollback／policy tests，分開 module 與真機 Files/iCloud 驗收，不碰 Mac 或其他 lane，不合併自己的 PR。
```

## 10 — iPhone／iPad UI｜L3 高

[完整交接文件](handoffs/10-adaptive-shell.md)

```text
請執行 docs/ios/handoffs/10-adaptive-shell.md（L3 高推理）。先讀 agent.md、docs/ios/README.md 與 docs/ios/contracts.md。從整合角色公布的 IOS_BASE_SHA 建立自己的 phase3-ios-adaptive-shell worktree。只修改 handoff 的 owned paths，完成 iPhone／iPad adaptive views 與 scene-scoped action routing，以 frozen interfaces 與 test doubles 驗證。保留同一 editor／preview instance，不修改 source／儲存／composition policy。不改共用檔案、不自行 merge，交付 PR／named tests／待整合與真機清單。C0 未公布前先做來源調查與案例，不發明平行 API。
```

## 11 — 驗收／效能／無障礙｜L3 高，race／IME 歸因 L4

[完整交接文件](handoffs/11-validation.md)

```text
請執行 Plainsong iOS 的 11 跨模組驗收（L3 高推理，race／IME 歸因需要 L4）。先讀 agent.md、docs/ios/README.md、docs/ios/contracts.md、docs/ios/handoffs/11-validation.md。從公布的 IOS_BASE_SHA 建立 phase3-ios-validation worktree，只修改 IOSAcceptanceTests 和自己的 evidence；target wiring 交 12，production composition 交 13。先寫 deterministic barriers／fixtures／manual scripts，providers 到位後測 exact integration head。驗證 stale saves／asset reads／image rollback、iPhone／iPad、中文、鍵盤、VoiceOver、100KB／1MB 效能，分開 mock、simulator、真機和 CI 證據。使用共享 Xcode 鎖；不弱化測試以換綠燈，不自行 merge 或改其他 lane。
```

## 12 — 建置／IPA｜L2 中，L3 review

[完整交接文件](handoffs/12-build-and-ipa.md)

```text
請執行 Plainsong iOS 的 12 建置與未簽名 IPA（L2，簽名／IPA／平台隔離須 L3 review）。先讀 agent.md、docs/ios/README.md、docs/ios/contracts.md、docs/ios/handoffs/12-build-and-ipa.md。使用 phase3-ios-build-and-ipa worktree，等待 13 C0 明確交接全域 manifest。只修改 project.yml、Makefile、Scripts/ios、獨立 ios.yml 和本線 build 文件；不改 product source 或 package manifests。實作固定 ios-build／ios-test／ios-archive／ios-ipa 入口，保留 Mac target 與命令，iOS-only packages 不進 Mac swift test loop。採共享 Xcode 鎖、手動 CI，產出 arm64 device Release unsigned IPA、校驗碼和 nested signing／source SHA metadata。BUILD PASS 與 owner 重簽 INSTALL OPEN 分列，不保存簽名資料、不發布、不自行 merge。
```

## 13 — C0／整合角色｜L4 極高

[完整交接文件](handoffs/13-integration.md)

```text
請擔任 Plainsong iOS 平行開發的 13 整合角色（L4 極高推理），執行 docs/ios/handoffs/13-integration.md。先讀 agent.md、docs/ios/README.md、docs/ios/contracts.md 與所有 lane handoffs。保留 owner checkout，以獨立 phase3-ios-integration worktree 先交付 C0 可編譯契約、package/App target scaffold、唯一檔案所有權和可抓取 IOS_BASE_REF + 精確 IOS_BASE_SHA，建立可審查 PR後交接 shared manifests。其他線之後才依共同基準實作；你維持 central docs/contract與production composition。M0真機關卡未過不能接完整App。不要發假成功provider、不自行merge、不force-push；每次交付分列local、exact-head CI與owner-only gates。
```
