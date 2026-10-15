# iOS 並行開發驗收修正交接 — 2026-10-13

本批 source 修正已整合到獨立審查分支；**完整 iOS 首版驗收仍為 OPEN**。06 的正式 Workspace/Access provider、11 的產品驗收 harness、13 的 production composition 尚未交付。M0 真機關卡未關閉，這次沒有啟用正式產品接線。

## 審查基準

- Frozen C0：`642cb212703220409874a2741c5adbfb8c80fe8a`，13 frozen files 保持原 SHA-256。
- 原 11 個已交付 lanes 的精確 source heads 被組成審查基準 `9ddd0c3cc0b3cb3439ed296400abbb701eb48886`。
- 獨立 worktree：`codex/ios-review-integration`；公開 runner 實測 head `c1c250a2b5c3e518108356b0c598064d4d1b0bb4`；後續 Mac sandbox link 修正 `f619cf6`、唯一 preview fixture helper 修正 `3570d31` 分別有 source-bound 證據。新 full94 未重跑；不把窄測或 docs 當成全產品重測。
- 本批沒有寫入 owner checkout、原 lane branches/PR bases 或 `main`；其他並行工作的變動不屬於本批。沒有自行 merge。

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
| 07 Preview tests | real committed bundle 複製並逐 byte 核對；每次 JS 回覆有 deadline；throwing wait 和立即 cleanup | 不改 CSP/JS bundle/security policy；實際 native ready 結果見下方；首次真 bundle 載入仍 FAIL |
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
| Document lane | aggregate46 PASS；六個 guard 各1 named FAIL、restore後46 PASS；0 skip/timeout | storage117 inputs一致；task copy148逐次restore一致；與aggregate全148僅138相同，10差異是full PreviewKit，非storage依賴 |
| Aggregate App/Authoring/Images/Shell | 192 actual native PASS、0 fail/skip | 含 authoring/images 與 shell contracts/guards；不證明 physical IME、真 Files provider 或 production composition |
| PreviewKit iOS library / package | 舊generic product BFT只有library，0 test bundles；新Package scheme真94 compiled/94 executed＝90 PASS/4 FAIL | 舊入口不證明tests編譯；錯46 inventory保留並更正94；完整native結果不是PASS |
| PreviewIOSHosted fixture修正 | 原2 gate1 PASS/1 FAIL；修正alias後再2 actual＝1 PASS/1 FAIL；0 skip | fixture64files byte-equal/cleanup已驗證；realbundle現在到ready階段仍8s timeout，v1 preview gate FAIL |
| Aggregate iOS actual runner | c1 head build/test/source verify exit0；294 PASS/0 fail/skip，原17與C0 smoke12全PASS | 實際App192、Editor17、MarkdownCore2 selected、Syntax8、WorkspaceCore29、WorkspaceKitIOS46；Core322 compiled不等於322 iOS執行 |
| 2026-10-09 native歷史樣本 | storage41、authoring93 PASS | 舊候選快照；不涵蓋新 close/autosave3與async-source2，不當作最新 source 的驗收 |
| Exact-head Mac CI | 46ef53e/run38359852530 FAIL；c1/run38365268053 hardlink69/full362 PASS，但manualsandbox link缺WorkspaceCore而FAIL | 一行module list修正後local69＋actual signed sandbox PASS；新final head CI另追蹤。兩次原失敗均保留，Mac CI不是UIKit證據 |
| 原17反例重播 | 17/17 actual PASS，required gate exit0 | 同c1 sealed xcresult294；Oct9的10 PASS/7 FAIL仍保留作歷史反例 |
| 真機 / 安裝 / 效能 / 無障礙 | OPEN | iPhone/iPad 實際 IME、Files/iCloud、background、owner re-sign/install與量測均待 owner |

新 source 經後續 comment/formatter-only delta 才提交的情況，lane receipts 同時保留 tested bytes、final bytes 與 token/literal 相同比對，不能說 final bytes 已再次執行。Swift Testing 另行顯示 0 cases 的 footer 未算入 XCTest PASS 數。

## Mac CI hard-link 回歸修正

初次 exact-head CI 在未經本批修改的 `testHardLinkInspectionUsesCurrentKernelSpelling` 出現 `destinationAlias`。舊測試假設最後一次open決定vnode pathname；當時未記錄actual bytes，具體kernel/cache原因仍未歸因。新增nil-default原始syscall observer與明確test-only spelling seam；production仍做一次真fcntl及同一byte-exact guard。Native測試依同次actual bytes、非空absolute path斷言；另兩個controlled cases要求matching成功、mismatch inspect/publish拒絕、零staging/零publish、原檔不變。

Final source `f426077` 的**69 focused/362 full PASS、0 skip**；移除guard時**1 named FAIL**，恢復三個source hashes後重跑通過。這是Mac regression，不是iOS provider或IME證據。見[完整receipt](mac-ci-hardlink.md)、[proof](mac-ci-hardlink-proof.json)、[實際telemetry](mac-ci-hardlink-telemetry.json)。Local observation不解釋歷史CI kernel/cache cause。

## 模擬器與 hosted 入口

Owner明確授權重啟共用CoreSimulator後，只對已驗明PID/UID/executable的服務送SIGTERM。未直接signal其他任務的xctest、未shutdown all。裝置探索/showdestinations隨後恢復，public `make ios-test` 在 task-owned iPhone17 `A24A1CB9-2861-4AA4-A79F-E53F768950D8`／iOS27實際完成294 cases。Xcode27.0(27A5194q)/SDK27、最低deployment26；不聲稱已在iOS26真機測試。

全程使用 `/private/tmp/plainsong-xcodebuild-test.lock`。Public runner維持on-failure diagnostics，外層1200s watchdog未觸發；其driver正常exit0。Stack sample顯示曾等simctl diagnose的600s後處理，這個觀察不歸因原服務卡住。Storage受控負向runner採never diagnostics，與public不同且明記；六個實際named assertion FAIL後全source restore，positive46 PASS。

Standalone full Preview必須用`PreviewKit-Package`且核對test bundle/cases。首次`PreviewKit` product scheme空TestConfigurations、0 xctest/0 executed、admission exit65，已保留。第二輪full94 source-bound90 PASS/4 FAIL；source檔頭`#if os(macOS)`只包import的情況不能誤當整檔Mac-only，原錯46inventory與更正94都保留。

真bundle原失敗確認為test helper在`/tmp`/`/private/tmp` aliases上用字串長度計relative path。Foundation deterministic proof：64原始rawrelative均錯；新helper雙方normalized components＋validated prefix，64 byte-equal且failure cleanup PASS。唯一test file修正後native2仍1 PASS/1 FAIL：synthetic bridge/latest-document PASS，realbundle `bundle ready`8s throwing timeout。**Fixture缺陷修正不等於preview runtime PASS。**另三個Export失敗是ready timeout、offline navigation failure和60s XCTest timeout，原因未確認；未用綠色rerun、放寬deadline、skip或移除assertion關閉。

GitHub default main未註冊ios.yml；Mac CI不執行iOS。C1的Mac suites通過後，check-export-sandbox-root.sh漏掉新WorkspaceCore物件，這個link原因已確認；一行修正後local69＋signed sandbox negativecontrols PASS。新PR head CI結果在交付包hosted-ci-latest.json，避免用舊head結論代替。

## Claude／下一個 agent 的操作順序

1. Review獨立PR fixes/base及全部失敗嘗試；核對13 frozen、source manifests、actual named cases、byte-equivalence與唯一fixture test delta。原feature PR bases不改、maintainer merge。
2. 原17、C0 smoke12、aggregate294與storage六負向/restore46已實測；除非source相關變更或新問題，不必為收據重跑同樣邏輯。
3. **07 native preview診斷（高／需Swift concurrency及WebKit經驗）：**先查realbundle首個ready timeout；以實際navigation/JS/bridge lifecycle與owned PID telemetry定位，分清headless harness、runtime和產品原因。保留old full94與新2失敗；不因synthetic page或warm rerun通過宣稱首次bundle成功。三個deferred Export失敗另列，不歸因cold/entitlement而無證據。
4. **06 Workspace/Access（很高）：**真security-scoped leases/bookmarks、Files/iCloud協調讀寫與asset reader仍無實作。按原allowlist/ frozen contracts完成provider與negative cases。
5. **11 product validation（高）：**補完整產品harness/fixtures/實際named gates；目前沒有target。模組fake、compile、Mac CI不代替end-to-end provider/device/performance。
6. **13 production integration（很高）：**M0真機及realproviders滿足後才接composition；目前capabilities仍nil，App入口仍C0。
7. owner補iPhone/iPad真機IME/Undo、Files/iCloud/offline/move/delete、background/recovery、VoiceOver/keyboard/window、具名效能量測與重簽IPA launch/open/save。這些不由模擬器關卡代替。

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

- [actual294/原17/C0 smoke12](native-aggregate/receipt.json)、[storage六負向與restore46](../lane-05/native-guard-receipt.md)
- [native Preview詳細失敗與fixture修正](preview-native/README.md)、[manual sandbox link修正](mac-sandbox-link/receipt.json)
- [最新aggregate編譯](aggregate-generic-receipt-2.json)、[當時source inputs](aggregate-tested-source-2.json)、[compiled methods](aggregate-compiled-test-symbols-2.json)
- [跨快照source核對](proof-scope-verification.json)、[frozen合約](frozen-contracts-verification.json)
- [MacPreview94](preview-mac-receipt.json)、[MacWorkspace29](workspace-core-receipt.json)、[最新architecture](mac-architecture-receipt-2.json)、[最新lint](lint-receipt-3.json)、[原lane PR當前heads](original-lane-pr-heads.json)
- [05 latest](../lane-05/autosave-review-receipt.json)、[08 latest](../lane-08/exact-source-delivery-review.md)、[09 latest](../lane-09/acceptance-review-fixes.md)、[03/10/12](../lane-12/review-fixes-20261013/README.md)

Raw Xcode logs以可逆gzip保留，`gzip -dc <file.log.gz>`取得原始bytes；log-packaging.json列未壓縮/壓縮雜湊。沒有修改raw內容來通過diff check。
