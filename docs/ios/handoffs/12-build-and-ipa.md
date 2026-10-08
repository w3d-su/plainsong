# 12 — iOS 建置、CI 與 unsigned IPA

先讀 [協作總覽](../README.md)、[凍結契約 C0](../contracts.md)、`agent.md` §15–17、`project.yml` 和 `Makefile`。

## 任務與智力需求

- **目標：** 加入獨立 iOS target 與可重現入口，產出 simulator test 證據及 arm64 Release unsigned IPA，保留全部 Mac target／命令／測試行為。
- **最低智力：L2；簽名、IPA 和 scope 由 L3 review。** target wiring、shell runner 和 artifact 打包屬固定規格工作；但把 simulator 產物誤當 device IPA、遺漏嵌入 framework 簽名、混用 entitlement 或污染 Mac 測試會讓交付失效，必須由 L3 審查。
- **分支：** `phase3-ios-build-and-ipa`，專屬 worktree。C0 前先設計 toolchain preflight／腳本／workflow；C0 與 13→12 檔案交接後才寫正式全域檔案，完整 build 等實作 providers 到位。

## 檔案所有權

| 可修改 | 用途 |
|---|---|
| `project.yml` | 正式 iOS App、測試 target、packages、resources、schemes 和文件型別的唯一 manifest writer。 |
| `Makefile` | 追加獨立 iOS 入口及必要 iOS lint paths；保留既有 Mac 命令行為。 |
| `Scripts/ios/**` | iOS toolchain preflight、固定鎖 runner、simulator build／test、device archive、IPA 包裝和 metadata。 |
| `.github/workflows/ios.yml` | 預設僅 `workflow_dispatch` 的獨立 iOS CI。 |
| `docs/ios/build-and-ipa.md`、`docs/ios/evidence/build/**` | 建置／自行簽名安裝指南與建置證據。 |
| `docs/ios/handoffs/12-build-and-ipa.md` | 本任務交接文件。 |

不得修改 `App/**`、`AppIOS/**` 產品實作、package manifests、既有 `.github/workflows/ci.yml`、Mac `Scripts/release.sh` 或共用測試腳本。正式 iOS package stub／App entrypoint／test bootstrap 屬 **13 Integration**，不是本 lane。若 XcodeGen 需要新 ignored generated metadata 規則，交給 13 更新 `.gitignore`。任何跨 lane 檔案變更先由協調者修訂 ownership。

## 依賴與 C0 契約

- 13 提供 C0 module manifests、App entrypoint 與 stub，02／03／04／05／06／07 提供可編譯 package implementations。**全域 manifest／build 檔案在 bootstrap 期間由 13 建立最低 scaffold；C0 freeze 時 13 明確交接給 12，之後 12 是唯一 writer，13 不再同步修改。** 12 只引用 C0 的正式 target／product 名稱，不自建另一組 package stub。
- 11 提供 acceptance sources 和 required-resources manifest；由本 lane 把它們接進 iOS scheme，不改 tests。模組自己的 tests 納入 iOS simulator test scheme 或明確獨立入口，保留 named target 結果。
- 01 M0 真機 PASS 限制正式產品接線；建置 stub／mock 及原型可先做。完整 IPA readiness 還需 11 正式裝置驗收及 owner 自行簽名後啟動／Files 讀寫，unsigned 打包成功不能關閉它們。
- 固定最低 iOS／iPadOS 26、iPhone＋iPad、single scene；iOS bundle identifier 與 Mac 分離，文件型別沿用 `.md`／`.markdown`／`.mdx`。不得把 Mac sandbox／hardened-runtime／bookmark entitlements 整份複製到 iOS。

## 實作規格與入口

### Manifest 與平台隔離

- `project.yml` 新增 `PlainsongIOS` App scheme 與 C0 test targets。Mac `Plainsong`、`PlainsongTests`、`PerformanceTests`、`PlainsongUITests`、deployment target 14.0、原 resources 和其 scheme test list 保持原值。
- App source 使用 C0 的 `AppIOS/**`；preview resources 引用已提交的 `App/Resources/preview` folder，不製作另一份未同步 bundle。新增 iOS test resources 用 11 的 manifest，保留相對 bundle 路徑。
- 目前 `Makefile` 的 `PACKAGES := MarkdownCore EditorKit PreviewKit WorkspaceKit` 是 Mac `swift test` 迴圈。**禁止把 `EditorKitIOS`／`WorkspaceKitIOS` 直接加入這個迴圈。** 共用 `SyntaxKit`／`WorkspaceCore` 的回歸入口按其平台能力分開配置，不讓 iOS UIKit 套件在 Mac host 上執行。
- 新入口不能讓 `make build`／`make test`／`make release` 預設建 iOS、選裝置或產出 IPA。格式 lint 可由 13 需求追加 iOS 路徑；SwiftFormat 仍固定 0.62.1，不順手升级全 repo。

### 可重現命令

交付以下介面，`IOS_DESTINATION` 必須使用實際 simulator UUID；下面為**待本 lane 實作的新命令**，並非基線已存在的命令。

```sh
make ios-build IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'
make ios-test IOS_DESTINATION='platform=iOS Simulator,id=<installed-uuid>'
make ios-archive IOS_OUTPUT_ROOT=/private/tmp/plainsong-ios-release
make ios-ipa IOS_OUTPUT_ROOT=/private/tmp/plainsong-ios-release
```

- `ios-build`：generate → preflight → `PlainsongIOS` Debug simulator build，明確 destination／SDK、關閉 signing，使用每 head／run 隔離 DerivedData。
- `ios-test`：generate → preflight → simulator build-for-testing → resource preflight → test-without-building；`-parallel-testing-enabled NO`，寫出 logs／xcresult／實際 named tests，退出碼保留管線原始結果。
- `ios-archive`：generate → preflight → generic iOS arm64 Release archive；`CODE_SIGNING_ALLOWED=NO`／`CODE_SIGNING_REQUIRED=NO`、明確輸出 `.xcarchive`；驗證為 iphoneos device executable、包含 C0 要求資源和 framework，非 simulator app。
- `ios-ipa`：在同一固定鎖 runner 內完成／验证對應 head archive，從 archive 的 `Products/Applications/PlainsongIOS.app` 複製到獨立 staging `Payload/PlainsongIOS.app`，保留 bundle 和 frameworks，再 zip 為 IPA。禁止混入 DerivedData、私有文件、Provisioning profile、keychain 或 credential。輸出 `.ipa`、`.sha256` 和 signing-state／build metadata。
- 所有 SDK／XcodeGen／CLI flags 均在實作時用 `ctx7` 與 Apple 官方文件核對，並以 `xcodebuild -version`／SDK inventory／destinations 實證；需 iOS 26 SDK 與 runtime。缺少工具／destination 要早期失敗並明示，不猜用不存在的 simulator 名稱。

不使用有簽名需求的 generic `-exportArchive` 流程冒充 unsigned export，也不承諾任何免費簽名服務可用。若 Xcode 產出帶簽章的內嵌 framework，檢查所有 nested code 的簽名狀態；在工作副本按實際工具鏈移除並驗證，使「unsigned」描述與產物一致。移除失敗則標示交付失敗，不能只檢查 App 最外層。

### 固定鎖、CI 與 metadata

- 每個公開 iOS runner 的外層取得 `PLAINSONG_XCODEBUILD_LOCK=/private/tmp/plainsong-xcodebuild-test.lock`，同一 process tree 的 generate／xcodebuild／simulator／UI／device／wall-clock run 全程持有鎖；內層 helpers 不再次取鎖。若 user 指定不同 lock path 要明示拒絕或由協調者統一修改所有 lane，避免各自用不同鎖。
- 參考 `Scripts/run-export-html-e9.sh` 的 `lockf` 與 quiet admission；`Scripts/run-hosted-tests.sh` 本身沒有鎖，Mac runs 必須由協調者用同一外層鎖排程。不要為 iOS 改它。未取得鎖只回報排程等待，不 kill 其他 run。
- `.github/workflows/ios.yml` 預設只有 `workflow_dispatch`，不加 `push`／`pull_request` 觸發以控制 private Mac runner 費用。runner image／Xcode 固定於實作時驗證能提供 iOS 26 SDK 的版本；記錄 image＋toolchain。每 ref 使用 concurrency group，保留 run id／attempt，artifact 限本次暫存 evidence，失敗亦上傳。
- metadata 包含 source SHA／dirty state、C0 版本、命令與參數、Xcode／SDK、destination／architecture、configuration、fixture／bundle hashes、archive／IPA hashes、每個 code bundle 的簽名檢查、起訖時間、exit codes；不得 dump 完整環境或 secrets。宣告可重現流程，不宣稱未經證明的逐位元一致 IPA。

## 測試與 failure gates

- 首次／改 manifest 後 `make generate`，核對生成 project 的 target／scheme inventory；不手改 `.xcodeproj`。再跑 simulator build／named tests、device archive、IPA unpack／Mach-O platform／資源／nested signing-state 檢查。
- shell syntax 和參數錯誤／destination 不存在／missing resource／archive 非對應 head／錯誤平台等負向測試須有明確 nonzero 結果；不能誤包前一輪 IPA。staging／清理限本 runner 自己產出的目錄。
- shared changes 跑原 Mac `make build`、必要 `make test` 和 pinned lint／`git diff --check`；固定鎖下序列化，記錄 tests 真正執行數與 failures。共用模組回歸責任仍由 module owner，12 不用改測試期望藏平台問題。
- iOS CI 僅能证明該 workflow 的確切 head；rerun 不覆蓋失敗 attempt。CodeQL 若有是資訊項，不等待它關閉產品功能關卡。
- unsigned IPA 只能交付為 **BUILD PASS / INSTALL OPEN**，直至 owner 完成自行簽名安裝與 Files 讀寫。signed device test 沒執行、免費帳號授權期限或安裝工具相容性未確認時，明確記錄 OPEN，不捏造支持承諾。

## 交付與 review

交付一個 build PR：manifest＋腳本＋預設手動 CI、固定命令指南、SHA-256、signing-state metadata 和 exact-head build／test／IPA structural evidence。大 binary 放 `/private/tmp` 或批准的 artifact location，docs 只存索引與校驗碼。指南說明 IPA 需 owner 簽名、安裝驗證和重新簽名流程的實際觀察，不保存 credentials，也不自行發布、上傳商店或操作使用者簽名帳號。

L3 reviewer／Claude 核對 Mac manifest／命令未變、套件平台分離、固定鎖覆蓋、無簽名／密鑰材料、device platform／nested frameworks、CI 觸發費用、測試資源和可重跑命令。完成後向 13 回報 **local / exact-head hosted / owner installation** 三類狀態，maintainer 才處理 merge。

## Evidence（由執行者填寫）

尚未執行；基線沒有這些 iOS 命令／target，本文件沒有 simulator build、device archive、IPA 或安裝通過證據。

## 可直接貼給 agent

```text
請執行 Plainsong iOS 的 12 建置與未簽名 IPA（L2，簽名／IPA／平台隔離須 L3 review）。先讀 agent.md、docs/ios/README.md、docs/ios/contracts.md、docs/ios/handoffs/12-build-and-ipa.md。使用 phase3-ios-build-and-ipa worktree，等待 13 C0 明確交接全域 manifest。只修改 project.yml、Makefile、Scripts/ios、獨立 ios.yml 和本線 build 文件；不改 product source 或 package manifests。實作固定 ios-build／ios-test／ios-archive／ios-ipa 入口，保留 Mac target 與命令，iOS-only packages 不進 Mac swift test loop。採共享 Xcode 鎖、手動 CI，產出 arm64 device Release unsigned IPA、校驗碼和 nested signing／source SHA metadata。BUILD PASS 與 owner 重簽 INSTALL OPEN 分列，不保存簽名資料、不發布、不自行 merge。
```
