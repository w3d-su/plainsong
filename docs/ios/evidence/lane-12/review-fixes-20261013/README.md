# 03／10／12 review 修正與真實工具驗證

日期：2026-10-13。隔離 branch `codex/ios-shell-build-review-fixes`；owner checkout 與原 lane worktrees 未修改。
本次 source fixes 是 03 opaque ID、10 workspace publication／empty-folder grant、12 tooling evidence gates；沒有實作 06 provider、11 harness，沒有接上 production composition，也沒有改 frozen C0 declarations。

## 修正 commits

| Lane | Commit | 結果 |
|---|---|---|
| 03 | `a718fc4` | stability-key variant tags＋length-delimited resource/path fields，避免任意 opaque bytes 和 duplicate encoding 碰撞；新增 3 個回歸 |
| 10 | `5f2da57` | 獨立發布去重的 workspace projection；空資料夾的新檔案目標要求 matching directory grant，沒有從現有檔案推授權父目錄；新增 4 個回歸 |
| 12 | `e97e0a3` | source-input manifests／archive digests／成功 receipt／精確 IOS arm64 gate；全新原子 ZIP；required executed XCTest gate；verified nested lock ancestry；含 AppIOSTests 輸入 |
| 12 | `3b1841c` | archive receipt 也須符合 IOS-C0-v1；增加 cross-contract rejection fixture，澄清 signing-material rejection |
| 12 | `3d4f671` | 安裝版本 help 核對後明確設定 on-failure diagnostics、個案 timeout 120／180 秒；記錄 test receipt policy |

## 證據分列

| 驗證 | 實際結果 | 邊界 |
|---|---|---|
| WorkspaceCore Mac XCTest | **28 執行／28 PASS／0 fail／0 skip**，exit 0；新 opaque-ID 3 cases 均執行 | clean `3b1841c`；後續只修改 test runner／文件，WorkspaceCore source/test hashes 不變。Swift Testing 額外顯示 0 cases 的另一個 invocation 未算入 28 |
| tooling fixtures | **21 執行／21 PASS／0 fail／0 skip**，exit 0；包括真實 nested canonical-lock positive | clean `3b1841c`；synthetic artifacts 只測工具拒收，不是 product providers。後續只有 test-runner policy／文件變更 |
| SwiftFormat 0.62.1 | 7 個變更 Swift 檔案 lint PASS | 沒有以另一個版本替代固定 formatter |
| 靜態檢查 | 4 Python AST／8 shell syntax／diff check PASS | 不能代替 XCTest execution |
| C0 simulator generic build | **exit 0**，Xcode 27.0 (27A5194q)，SDK 27；deployment 26.0 | clean `3d4f671545eb41190b1b8e7262bcd27349aad36e`，`generic/platform=iOS Simulator`，沒有 simulator case execution |
| C0 device Release archive | **exit 0**，真實 nested ios-archive，resource manifest＋preview byte parity PASS，精確 IOS/arm64 PASS | 同 clean `3d4f671`；完整 archive/source digest，非 stamp-only receipt |
| unsigned C0 IPA | **exit 0**；獨立 SHA、ZIP CRC、member set、MinOS 26.0、無 provisioning／signature 殘留與 source/archive/platform revalidation PASS | 有效 C0 tooling 產物，production capabilities 仍 unavailable |
| Shell simulator required 4 cases＋Core simulator required 3 cases | **PENDING** | Root 將以 aggregate runner 的 matching source hashes＋actual named cases 補證。這裡不把 generic build 計為 execution |
| Exact-head hosted CI | **NOT RUN** | 未 push／未觸發 ios.yml，沒有 hosted run ID |
| 真機／IME／Files／iCloud／背景／重簽安裝 | **OPEN** | 不由 synthetic fixtures、C0 build 或 unsigned IPA 關閉 |

前三個 WorkspaceCore admission attempts 都 exit 75、**0 execution**；tooling 曾因 positive admission 被其他 run 占鎖而回報一個 infrastructure pending，隨後完整 21-case run 已實際通過。C0 generic 第一次 runner admission exit 75（make wrapper exit 2），第二次才真正 build exit 0。保留所有 logs，不將排程未執行算成產品測試 failure。

`xcodebuild -help` 支援的四個 options 留在 [xcodebuild-help-options.txt](xcodebuild-help-options.txt)。Context7 解到官方 Apple Xcode library，但詳細 CLI 查詢沒有相符頁面，具體 flags 以已安裝官方 help 為準。Timeout 只約束個別測試，不解決或掩蓋 simulator installation stall；driver failure／0-run／malformed／missing required cases 仍失敗。

## 產物與重現

- IPA：`/private/tmp/plainsong-shell-build-review-20261013/release/PlainsongIOS-3d4f671545eb.ipa`，2,516,957 bytes。
- SHA-256：`138096c65c31faa674864cf6f093119d3dbc055cb26df0e86797730c238becdd`。
- Source fingerprint：`b0a6a7273be3da51500e210796e89fe7dee08a3abe6471e0bb5455e81fdc5343`；完整 [source-inputs.json](source-inputs.json)。
- Archive digest：`73c6d00f2280569edaed781d843a195c7ce940d4edd0a78822cd61b7f4c84d10`；[c0-archive.json](c0-archive.json) 與 [c0-ipa.json](c0-ipa.json)。
- Full local logs／binary／archive：`/private/tmp/plainsong-shell-build-review-20261013/`。這個目錄屬本次 task，沒有寫入 owner repo。
- [workspace-core.log](workspace-core.log)、[tooling-21.log](tooling-21.log)、[checkpoint.json](checkpoint.json)、[verification.json](verification.json) 保留實際 counts、tested head 與 source hashes。

```sh
# 在 exact code ref 3d4f671 的獨立 checkout 執行；每個 public runner 自己持 canonical lock。
make ios-build IOS_OUTPUT_ROOT=/private/tmp/new-ios-review-output
make ios-ipa IOS_OUTPUT_ROOT=/private/tmp/new-ios-review-output
make test-ios-tooling
# 個案 execution 必須使用真正已安裝且 discoverable 的 UUID，不能用 generic destination。
make ios-test IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>' IOS_OUTPUT_ROOT=/private/tmp/new-ios-review-output
```

這份 documentation 是 build 後的 additive evidence commit。嚴格 head gate 會拒絕在不同 HEAD 直接重包舊 archive；要換 HEAD 必須重新 build/archive，不能把歷史 binary 當作新的 head 證據。
