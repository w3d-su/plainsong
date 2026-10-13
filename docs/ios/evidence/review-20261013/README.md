# iOS 並行開發驗收修正交接 — 2026-10-13

本批 source 修正已整合到獨立審查分支；**完整 iOS 首版驗收仍為 OPEN**。06 的正式 Workspace/Access provider、11 的產品驗收 harness、13 的 production composition 尚未交付。M0 真機關卡未關閉，這次沒有啟用正式產品接線。

## 審查基準

- Frozen C0：`642cb212703220409874a2741c5adbfb8c80fe8a`，13 frozen files 保持原 SHA-256。
- 原 11 個已交付 lanes 的精確 source heads 被組成審查基準 `9ddd0c3cc0b3cb3439ed296400abbb701eb48886`。
- 獨立 worktree：`codex/ios-review-integration`；本批 iOS source head `4135301`；Mac CI 觀察/測試修正後的最後 code head `0f97875`。其後的 receipts/docs 不等於重新測試產品。
- owner checkout、原 lane branches/PR bases、`main` 未修改；沒有自行 merge。

## 本批修正

| 範圍 | 改後行為 | 審查重點 |
|---|---|---|
| 03 WorkspaceCore | Opaque identity 使用 variant 與長度編碼，任意 bytes/duplicate fields 不再碰撞 | 身分穩定、selection 不被重導 |
| 05 Document I/O | 外部 read 一開始即 fence writes；close/retire drain 已發出工作並保存較新復原稿 | 舊 save 只能更新 persisted baseline；來源/revision 不回退 |
| 05 Close/autosave | 關閉中完成的舊 autosave，retained draft reopen 後會重排 | current/open/unfenced/writable/dirty 全部成立才可重排；readonly/conflict 零寫入 |
| 08 Find | 接受與使用結果都核對 binding、identity/revision、exact raw source | 包含相同 revision 但 source 已變的 async delivery |
| 08 Find scheduler | 一個 running scan、一個 latest pending，舊 worker drain 後才啟動下一個 | 過期結果不授權取代 |
| 08 Frontmatter | immutable snapshot 更新 projection，保留 draft 的原始授權；Add 重讀來源並拒絕重複/錯誤 block | 更新呈現不寫 source、不新增 Undo |
| 09 Images | Task cancellation 在各 await 後/pre-apply 檢查；terminal cleanup 一次；已接受 source edit 仍 commit ownership | cancel 無插入、rollback 不誤刪其他 operation；Undo 不刪圖 |
| 09 Raster | 完整 ImageIO container/status 與第一張 raster 即時解碼 | 不再接受只有簽頭的偽 PNG/JPEG/GIF；不是所有 animation frames 解碼 |
| 10 Shell | tree-only refresh 發布 projection；空資料夾新檔目標只用 matching explicit directory grant | 不隱式取得父目錄授權 |
| 12 Tooling | source/archive/platform/contract receipts、原子 ZIP、實際 named tests、nested lock ancestry | 舊 archive、simulator binary、0-run/all-skip、forged lock 均拒收 |
| 07 Preview tests | real committed bundle 複製並逐 byte 核對；每次 JS 回覆有 deadline；throwing wait 和立即 cleanup | 不改 CSP/JS bundle/security policy；iOS runtime 仍待執行 |
| Central inventory | 架構測試符合已批准的 SyntaxKit/WorkspaceCore 抽取，保留原第三方 pins | 沒有停用 mutation/layering guards |

Readonly Undo 的原始反例已通過，沒有為未證實問題修改 editor history。這次未增加依賴，未改 wire protocol、CSP 或 preview bundle。

## 證據邊界

| 檢查 | 真正取得的結果 | 能證明的範圍 |
|---|---|---|
| Mac PreviewKit | 94 XCTest PASS、0 fail、0 skip；exit 0 | Mac 共用預覽回歸，包含真實 tables/code/math/Mermaid/MDX 與 deadline tests |
| Mac architecture inventory | 新code head0f97875上5 named XCTest PASS、0 fail、0 skip；exit 0 | parser/workspace 抽取的 dependency inventory/layering |
| Mac WorkspaceCore | 整合後29 XCTest PASS、0 fail、0 skip；exit 0 | 包含原始 opaque identity 反例；lane歷史28另外保留 |
| Tooling fixtures | 21 unittest PASS；exit 0 | receipts/ZIP/named-result/lock 的正反向工具測試；不是正式 provider |
| Authoring/Images portable harness | 149 XCTest PASS、0 fail、0 skip；exit 0 | 89 Authoring＋60 Images 的 Mac 可攜邏輯；排除 UIKit views/native adapters，2 manifests 是測試 copy 專用 Mac metadata |
| Portable guard mutations | 6 cases 實際執行：5 預期 FAIL＋1 accepted-commit control PASS；exit 1 | 移除 exact-source/cancellation/raster guards 能被測出；candidate 未保留 mutation |
| Document lane | 最新 46 declared＝46 compiled；generic iOS BFT exit 0；0 executed | aggregate storage相關117/117 inputs一致；完整lane manifest138/148一致，10差異都是完整PreviewKit port/tests，不是148/148 |
| Authoring/Images lane | 155 named App cases compiled；generic BFT exit 0；0 native executed | 149 邏輯＋6 contract cases；native Undo/IME/provider 不在此證據內 |
| PreviewKit iOS package | generic BFT exit 0；0 executed | UIKit/真實 bundle 測試分支可編譯；不代替 iOS real WebKit runtime |
| Aggregate iOS BFT | 新code head0f97875再驗 exit 0、source verify exit 0；原17 cases全部編入 | 6 test bundles：App192、Editor17、MarkdownCore322、Syntax8、WorkspaceCore29、WorkspaceKitIOS46個unique symbols；全為編譯／0 execution |
| 2026-10-09 native歷史樣本 | storage41、authoring93 PASS | 舊候選快照；不涵蓋新 close/autosave3與async-source2，不當作最新 source 的驗收 |
| Exact-head Mac CI | 初次 head46ef53e / run38359852530 FAIL：WorkspaceKit360中的1個既有hard-link test；修正後待新head CI | 初次Typecheck/lint、MarkdownCore322、Preview94通過；full Test在WorkspaceKit停止，Build skipped；保留失敗，不當作iOS結果 |
| iOS runtime / 原17反例重播 | OPEN | 保留 Oct9 的10 PASS/7 FAIL原始結果；最新 source尚未完成完整重播 |
| 真機 / 安裝 / 效能 / 無障礙 | OPEN | iPhone/iPad 實際 IME、Files/iCloud、background、owner re-sign/install與量測均待 owner |

新 source 經後續 comment/formatter-only delta 才提交的情況，lane receipts 同時保留 tested bytes、final bytes 與 token/literal 相同比對，不能說 final bytes 已再次執行。Swift Testing 另行顯示 0 cases 的 footer 未算入 XCTest PASS 數。

## Mac CI hard-link 回歸修正

初次 exact-head CI 在未經本批修改的 `testHardLinkInspectionUsesCurrentKernelSpelling` 出現 `destinationAlias`。舊測試假設最後一次open決定vnode pathname；當時未記錄actual bytes，具體kernel/cache原因仍未歸因。新增nil-default原始syscall observer與明確test-only spelling seam；production仍做一次真fcntl及同一byte-exact guard。Native測試依同次actual bytes、非空absolute path斷言；另兩個controlled cases要求matching成功、mismatch inspect/publish拒絕、零staging/零publish、原檔不變。

Final source `f426077` 的**69 focused/362 full PASS、0 skip**；移除guard時**1 named FAIL**，恢復三個source hashes後重跑通過。這是Mac regression，不是iOS provider或IME證據。見[完整receipt](mac-ci-hardlink.md)、[proof](mac-ci-hardlink-proof.json)、[實際telemetry](mac-ci-hardlink-telemetry.json)。Local observation不解釋歷史CI kernel/cache cause。

## 模擬器與 hosted 入口

Xcode 27.0 (27A5194q)/SDK27，最低 deployment26。已建立並成功 boot 的本任務 simulator `A24A1CB9-2861-4AA4-A79F-E53F768950D8` 後來仍被 xcodebuild/DVT 拒絕 destination，`simctl` discovery 也超時。既有 run 曾卡在 install；這些是 infrastructure/0-run，不是產品 PASS，也沒有建立可歸因的 root cause。

未重啟 shared CoreSimulatorService，未 kill 其他任務的 suspended xctest、未 shutdown all。所有 heavy work使用 `/private/tmp/plainsong-xcodebuild-test.lock`；admission exit75與被中斷driver的外層exit75分開記錄。

GitHub default `main` 未登錄 `ios.yml`，workflow API/default file 404。既有 Mac `CI` 跑 `make lint/test/build`，不會執行 iOS tests。本批不以更改 CI 或 rerun 隱藏 runtime缺口。

## Claude／下一個 agent 的操作順序

1. Review 本批 PR 的 fixes diff；base 是獨立的已交付 lane aggregate。不要把 review-baseline 合入 `main`，不要改原13份PR的base。
2. 核對 final source manifest、13 frozen hashes、tested bytes/nonsemantic deltas、實際 named cases與所有失敗嘗試。
3. 在可用 runtime 上以 canonical runner重跑整合後 `make ios-test`，再用本批 `original-17-required.txt`核對原17個 cases真的PASS；其中opaque ID反例已另在Mac純邏輯測試通過。個案0-run/all-skip/missing均不接受。
4. 單獨執行 full PreviewKit iOS package real-bundle測試；App scheme僅link PreviewKitContracts，不會因此驗證完整WebKit預覽。
5. 重跑 lane05 六個 controlled guard probes，包含移除 autosave resumption；保留 restore hashes。Portable六-case mutation只證明08/09的Mac邏輯。
6. 06 可先做 C0 doubles/prototype，11 可先做穩定 harness/fixtures；M0真機 gates通過之後，13才能接 production providers。
7. owner補 iPhone/iPad IME/Undo、Files/iCloud/offline/外部move-delete、背景/recovery、VoiceOver/鍵盤/視窗與效能，以及重簽IPA launch/open/save。

重跑入口（新獨立 checkout，每個 public runner自行取得canonical lock）：

```sh
make ios-build IOS_OUTPUT_ROOT=/private/tmp/new-ios-review-output
make ios-test IOS_DESTINATION='platform=iOS Simulator,id=<discoverable-installed-uuid>' IOS_OUTPUT_ROOT=/private/tmp/new-ios-review-output
make test-ios-tooling
```

原17額外核對（`test-results.json`來自同一head真實xcresult extraction）：

```sh
python3 Scripts/ios/ios-test-results.py <test-results.json> \
  --required docs/ios/evidence/review-20261013/original-17-required.txt \
  --report /private/tmp/ios-review-original17.json \
  --names /private/tmp/ios-review-original17-names.txt
```

## IPA狀態

Lane12有已驗證的 unsigned **C0 tooling IPA**，source `3d4f671545eb41190b1b8e7262bcd27349aad36e`、SHA-256 `138096c65c31faa674864cf6f093119d3dbc055cb26df0e86797730c238becdd`。它的production capabilities仍unavailable；不能作為已完成首版App或本批final head binary。換head要重新archive，不能重包舊archive冒充。

審查PR body列本批最後確認與source head；可下載交接包的`delivery.json`另列PR/link、patch bundle和checksum。本報告是審查/交接，沒有關閉產品驗收。

## 直接證據索引

- [最新aggregate編譯](aggregate-generic-receipt-2.json)、[當時source inputs](aggregate-tested-source-2.json)、[compiled methods](aggregate-compiled-test-symbols-2.json)
- [跨快照source核對](proof-scope-verification.json)、[frozen合約](frozen-contracts-verification.json)
- [MacPreview94](preview-mac-receipt.json)、[MacWorkspace29](workspace-core-receipt.json)、[最新architecture](mac-architecture-receipt-2.json)、[最新lint](lint-receipt-2.json)、[原lane PR當前heads](original-lane-pr-heads.json)
- [05 latest](../lane-05/autosave-review-receipt.json)、[08 latest](../lane-08/exact-source-delivery-review.md)、[09 latest](../lane-09/acceptance-review-fixes.md)、[03/10/12](../lane-12/review-fixes-20261013/README.md)

Raw Xcode logs以可逆gzip保留，`gzip -dc <file.log.gz>`取得原始bytes；log-packaging.json列未壓縮/壓縮雜湊。沒有修改raw內容來通過diff check。
