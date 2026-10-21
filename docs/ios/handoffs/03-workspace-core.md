# 03 — WorkspaceCore：跨平台檔案樹與路徑模型

## 任務與智力需求

- **建議：L3 高階推理。** 需要把純模型與 macOS 檔案權限證明分離，同時保持既有檔案樹、搜尋、重新命名及搬移呼叫端的語義；直接搬檔很容易遺失 `mutationExpectation` 或改變 Unicode 路徑身分。
- Branch：`phase3-ios-workspace-core`。在自己的 isolated worktree 開發；基準及起跑 commit 依 [總表](../README.md)，不能修改 owner checkout。
- 目標：提供 macOS／iOS 共用、只依賴 Foundation／MarkdownCore 的檔案種類、root 身分、相對路徑、不可變 snapshot、tree reconciliation 與顯示狀態；保持 Mac 既有 public surface 與資料安全行為。
- 本 lane 不做掃描、bookmark、File Provider、檔案讀寫、UIDocument 或 UI。

## 起跑條件與並行關係

1. 13 integrator 完成 C0：合併 [contracts.md](../contracts.md)、WorkspaceCore manifest／空 target／測試入口後才開始新增實作。
2. 可和 02 SyntaxKit、04 EditorKitIOS 同時開發。06 browser／05 document IO 可先使用 C0 的 doubles；等本 lane 的真實 models 通過 tests 後再接線。01 專責 M0 真機驗證，MarkdownCore iOS support 由 13／C0 提供。
3. iOS M0 真機關卡未通過前，限於 core extraction、contract tests 與 prototypes，不以模擬器 green 宣告 Files／iCloud 可用。

## Exclusive write paths

允許修改：

- `Packages/WorkspaceCore/Sources/WorkspaceCore/**`
- `Packages/WorkspaceCore/Tests/WorkspaceCoreTests/**`
- `Packages/WorkspaceCore/Package.swift`
- `Packages/WorkspaceKit/Package.swift`（只新增 WorkspaceCore dependency，保留現有平台與 dependencies）
- `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceFileTree.swift`
- `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspacePathByteKey.swift`
- 新增 `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceCoreAdapter.swift`
- `Packages/WorkspaceKit/Tests/WorkspaceKitTests/WorkspaceFileTreeTests.swift`，以及自己新增的 `WorkspaceCoreAdapterTests.swift`
- 本 handoff 的 evidence section。

禁止修改其他 Package.swift、frozen `Contracts.swift`、`project.yml`、Makefile、CI、generated project、其他 lane、`agent.md`、Decision Log。把 global dependency／test target 需求與架構變更寫入 PR evidence，由 integrator 在同一整合 commit 寫入共用檔案。

## 現有程式與抽取策略

- `WorkspaceFileSnapshot.Entry` 和 `WorkspaceFileNode` 現在都持有 `WorkspaceItemMutationExpectation?`；這是 Mac physical-identity mutation proof，**不能移到通用 WorkspaceCore 或默默刪除**。
- 既有 snapshot `identity` 用於節點顯示與 reconciliation，不能當成寫入授權。新 core root／resource identity 依 C0 opaque contracts；Mac adapter 保留 mutation expectation sidecar，並在 tree 輸出重新附回原 public nodes。
- 將純 builder、排序、可見檔案過濾、展開／選取保留及 byte-exact path helper 抽取到 WorkspaceCore。Mac wrapper 委派 pure builder，再保留既有 expectation 欄位與呼叫端型別；不要一次修改所有 WorkspaceKit／App consumers。
- `WorkspaceRootContainment` 的 filesystem／symlink resolution 不屬於 pure core。只有相對路徑詞法檢查可共用；不把 `resolvingSymlinksInPath()`、Darwin、FSEvents 或 security scope 塞進 core。
- path bytes 必須保留 NFC／NFD、大小寫及字面 spelling。可用 localized natural compare 作顯示排序，最後以 UTF-8 bytes 作穩定 tie-break；不能因 `String ==` 的 canonical equivalence 合併兩個 entry。

## Contracts 與行為

- 共用型別為 `IOSWorkspaceIdentity`、`IOSFileLocation`、`IOSWorkspaceEntry`、`IOSWorkspaceSnapshot`；所有對外型別／簽名以 C0 為準，禁止自行另造同名 protocol；必要變更先回報 integrator。
- Root identity 代表一個 grant／workspace namespace；resource identity 是 root-specific opaque 值。File Provider 不保證 inode 穩定，不能以 Darwin device／inode 授權 iOS operations。
- Snapshot 必須帶 root identity 與 generation。舊 root 或舊 generation 的結果無法 reconcile 到新 workspace；同名路徑跨 root 不可沿用 selection／expansion。
- provider 有可靠 resource identity 時使用它；沒有時使用 root-specific byte-path fallback，fallback 只供顯示，不承諾跨 rename 追蹤。
- 相同 identity 出現在不同 path 時保留兩個 nodes，採既有 byte-path disambiguation，不能誤去重 hard link／provider aliases。
- 拒絕絕對、NUL、`..` escaping、空 leaf path；不能把 `/etc/a.md` 正規化成看似合法 `etc/a.md`。根節點使用明確 root marker，不拿空 leaf path 通過一般 path API。
- 預設保留既有 `.md`／`.markdown`／`.mdx`、image 與 show-all filter；tree 的「image」分類不等於 preview 的 raster allowlist。

## 測試與驗收

- Fixtures：filtered ancestors、數字排序、大小寫 tie、NFC／NFD、同 identity 不同 paths、缺 identity、跨 root 相同 path、無效 snapshot paths。
- 驗證同 root 新 snapshot 保留仍存在的 expansion／selection，刪除會移除選取；跨 root 不繼承 UI state。
- Mac adapter round-trip：每個 node 原 expectation 完整保留，search／mutation consumer 行為不變，pure model 未持有 Darwin proof。
- Negative probe：取消 root／generation guard、刪去 expectation sidecar 或把 path equality 改成一般 String equality，對應測試必須失敗。
- 實作時執行 `swift test --package-path Packages/WorkspaceCore`、既有 WorkspaceKit tree tests，再由 integrator 執行完整 Mac package／app regression。只讀測試名稱與實際 executed counts 要列入 evidence。

## Stop gates 與 PR evidence

- 需更動 snapshot safety proof、Mac mutation policy、任何 shared interface 或額外 consumers 才能完成：停在該界面，提交設計與失敗案例給 integrator，不能擴大寫入範圍。
- 驗收不能用「成功編譯」代替 Mac compatibility tests，不能把 UI node ID 當 access authority。
- PR 附起跑／base／head SHA、changed-path 清單、C0 version、fixtures、測試命令與 named-test counts、Mac before／after 比對、未過關事項、供 integrator 寫入 agent.md／Decision Log 的精確內容。
- 不改 `main`、不 force-push、不自行 merge。Claude review 必須能由此 evidence 檢查模型抽取與 authority 分離。

## Evidence（由執行者填寫）

執行日期：2026-10-08。契約：**IOS-C0-v1**。Worktree：`/private/tmp/plainsong-ios-workspace-core`。Branch：`phase3-ios-workspace-core`。Owner checkout `/Users/davis._.su/Documents/blogeditor` 仍在 `phase3-native-macos-polish`，工作樹只有既有的 `CLAUDE.md` 修改與未追蹤 `.omc/`。

### 基準

| 項目 | 值 |
|---|---|
| IOS_BASE_REF | `refs/tags/ios-c0-v1` |
| Base / IOS_BASE_SHA | `642cb212703220409874a2741c5adbfb8c80fe8a` |
| 遠端 tag | `git ls-remote origin refs/tags/ios-c0-v1` 回傳同一 SHA |
| 未用作程式基準的 integration tip | `3274bfc8ad7f70105fe10c03cb111cf987ca1800`（`phase3-ios-integration`）。台帳把它標成文件 receipt。本分支的 parent 是 tag，沒有 fast-forward。 |
| Head | 實作與這份 evidence 在同一個 commit，parent 就是上列 base。完整 head SHA 以 PR head 為準；commit 內不寫自己的 hash。 |

### 變更路徑

WorkspaceCore 的 `Contracts.swift` 與 `Package.swift` 保持 C0 凍結內容。新增：

- `Packages/WorkspaceCore/Sources/WorkspaceCore/WorkspaceDisplayNodeID.swift`
- `Packages/WorkspaceCore/Sources/WorkspaceCore/WorkspaceFileKind.swift`
- `Packages/WorkspaceCore/Sources/WorkspaceCore/WorkspacePathByteKey.swift`
- `Packages/WorkspaceCore/Sources/WorkspaceCore/WorkspacePureTree.swift`
- `Packages/WorkspaceCore/Sources/WorkspaceCore/WorkspaceRelativePath.swift`
- `Packages/WorkspaceCore/Sources/WorkspaceCore/WorkspaceSnapshotReconcile.swift`
- `Packages/WorkspaceCore/Tests/WorkspaceCoreTests/WorkspacePathIdentityTests.swift`
- `Packages/WorkspaceCore/Tests/WorkspaceCoreTests/WorkspacePureTreeTests.swift`
- `Packages/WorkspaceCore/Tests/WorkspaceCoreTests/WorkspaceSnapshotFixtures.swift`
- `Packages/WorkspaceCore/Tests/WorkspaceCoreTests/WorkspaceSnapshotReconcileTests.swift`
- `Packages/WorkspaceCore/Tests/WorkspaceCoreTests/WorkspaceSnapshotRejectionTests.swift`

WorkspaceKit：

- `Packages/WorkspaceKit/Package.swift`：只加入 `../WorkspaceCore` 與 library product。platforms 仍是 macOS 14。test target dependencies 未動。
- `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspaceFileTree.swift`：純 builder 移出。`reconcile(previous:snapshot:options:)`、snapshot、node、`mutationExpectation` 的 public 簽名保持原樣。`Entry.normalized` 仍保留開頭 `/`。
- `Packages/WorkspaceKit/Sources/WorkspaceKit/WorkspacePathByteKey.swift`：改成 internal `typealias WorkspacePathByteKey = WorkspaceCore.WorkspacePathByteKey`。搜尋、completion、ignore、overlay 繼續用這個名字；`.bytes` 仍是 public。
- 新增 `WorkspaceCoreAdapter.swift` 與 `WorkspaceCoreAdapterTests.swift`。
- `WorkspaceFileTreeTests.swift` 沒有修改。

同一次提交只另改本 evidence section。`agent.md`、Decision Log、`project.yml`、Makefile、CI、`Package.resolved`、App 與其他 lane 都沒有改。Makefile 的 `test-portable-core` 已經包含 WorkspaceCore。

### 模型

- 路徑相等與 `Hashable` 使用 UTF-8 bytes。Swift `String` 相等會把 NFC 與 NFD 視為同一個字串。
- `WorkspaceRelativePath` 拒絕空 leaf、絕對路徑、NUL、`..`、空元件與 `.`，並保留呼叫端 spelling。`/etc/a.md` 不會被改寫成 `etc/a.md`。Root 是 `WorkspaceTreeLocation.root`；`file(spelling: "")` 回傳 nil。
- Mac 絕對路徑仍由 `Entry.normalized` 保留 `/`。純 builder 沿用原本的 parent split：開頭斜線產生的空元件被丟掉，節點掛在 parent key `etc` 下，不會變成 root child `etc/a.md`。詞法拒絕用在新的 path API 與 IOS snapshot reconcile。
- 排序是 `caseInsensitive` + `numeric`，再用 UTF-8 bytes 做 tie-break。預設過濾保留 markdown／mdx、image 與目錄；`showAllFiles` 略過種類優先。Tree image 含 svg、heic、tiff，寬於 preview 的 PNG／JPEG／GIF／WebP allowlist。對應測試沒有 import `MarkdownImageAssetPolicy`。
- Mac device／inode proof 留在 `WorkspaceItemMutationExpectation`。Adapter 用 snapshot entry 的 index 當 sidecar；root index 是 `-1`，expectation 為 nil。
- IOS stability key 不含 workspace UUID。沒有 resource 時是 `0` 加 path UTF-8，rename 不追蹤。唯一 resource 是 `1` 加 resource bytes，rename 追蹤，entry UUID 不參與。同一 material 出現多次時再附加 `31` 與 path bytes，兩個節點都留下。
- 同一 workspace 且 `snapshot.accessGeneration` 較舊時回傳 `.rejectedStaleGeneration`，沿用先前的 expansion state。另一個 root 回傳 `.applied`，expansion 與 selection 是空的。entry 的 workspace、generation 不符，或路徑被拒時，省略該 entry 與它的子孫。混合 generation 的子 entry 是逐項省略；frozen snapshot 沒有 snapshot 級錯誤型別。
- Portable node 記錄 `entryID` 與 relative spelling，不複製 `fileURL`。
- `Packages/WorkspaceCore/Sources` 裡唯一的 Darwin 字樣是未修改的 `Contracts.swift` 註解。沒有 inode、`FileManager`、`mutationExpectation` 或 symlink resolution。

### 測試

還原 probe 之後：

- 2026-10-08 20:29:32，`swift test --package-path Packages/WorkspaceCore`。Build 2.25 秒。**25 tests，0 failures**（0.010 秒）。`WorkspaceContractTests` 1、`WorkspacePathIdentityTests` 5、`WorkspacePureTreeTests` 9、`WorkspaceSnapshotReconcileTests` 5、`WorkspaceSnapshotRejectionTests` 5。Swift Testing 套件是 0 tests。
- 2026-10-08 20:29:33，`Packages/WorkspaceKit` 的 `swift test --filter 'WorkspaceFileTreeTests|WorkspaceCoreAdapterTests|CompletionWorkspaceProviderTests'`。**19 tests，0 failures**。既有 `WorkspaceFileTreeTests` 10/10，含 `testReconcileTwoThousandFilesStaysUnderBudget` 0.027 秒（門檻 50 毫秒）。`WorkspaceCoreAdapterTests` 3/3。`CompletionWorkspaceProviderTests` 6/6。
- 2026-10-08 20:30:34，`swift test --filter WorkspaceSearchContractTests`。**18 tests，0 failures**。涵蓋 byte-key 排序、NFC／NFD overlay，以及空路徑、絕對路徑與 `..` 的拒絕。`WorkspacePathByteKey("")` 仍可建構。

SwiftFormat **0.62.1**（`/private/tmp/plainsong-swiftformat-0.62.1/swiftformat`）對 lane Swift 檔 lint 通過。本機 SwiftLint **0.65.0** 用 `--use-script-input-files` 只掃 16 個 lane Swift 檔，exit 0，沒有 finding。

### Negative probes

每次只改一個守衛，跑完即從備份還原。還原後三個來源檔與備份 `cmp` 一致，才跑上一節的綠燈。

1. 移除 stale-generation early return。`testStaleGenerationDoesNotReconcile` 失敗，訊息是 `expected stale generation to be rejected`。同輪 `testSameRootNewerGenerationKeepsSurvivingExpansionAndSelection` 通過。20:28:38，2 tests，1 failure。
2. Carry 分支改成 `guard let previous else`，拿掉 workspaceID 比對。`testSamePathAcrossRootsDoesNotInheritExpansionOrSelection` 失敗：`expandedKeys` 不是空的，`selectedKey` 仍在。同輪 stale-generation 測試通過。20:28:40，2 tests，2 failures。
3. Adapter 的 `mutationExpectation` 固定回 nil。失敗的是 `testAdapterRoundTripsMutationExpectationForEveryNode`、`testDuplicateIdentityKeepsEachPathExpectation`、`testCanonicalSpellingsKeepSeparateExpectations`、`testTreePreservesSnapshotMutationExpectation`。斷言看到 nil，而 fixture 仍是 device／inode expectation。20:28:45，4 tests，9 failures。
4. `WorkspacePathByteKey` 的 `==` 與 `hash(into:)` 改成 UTF-8 `String` 相等。失敗的是 `testByteKeyDoesNotTreatCanonicalEquivalentsAsEqual`（Set count 變成 1）、`testRelativePathPreservesDistinctUnicodeSpellings`、`testNFCAndNFDPathsStayDistinctNodes`（子節點被合併）。`testCanonicalSpellingsAndDuplicateResourcesStayDistinct` 仍通過：snapshot stability key 存的是 raw UTF-8，不讀這個 `==`。Hashable 改成 canonical 時，純檔案樹會合併；IOS snapshot 的節點清單仍靠 raw bytes 分開。20:28:48，4 tests，5 failures。

### 未過關與 integrator 筆記

- M0 真機、iCloud／Files、重簽 IPA 維持開放。本 lane 沒有宣告 Files 可用。
- C0 的 iOS simulator test execution 在台帳仍是 OPEN。這裡沒有跑 simulator。
- 完整 WorkspaceKit、Mac app 與 `make test` 由 integrator 跑。C0 台帳裡的 WorkspaceKit 計數是 357。
- 混合 generation 的子 entry 是省略，並連帶省略該 entry 的子孫。需要 snapshot 級 typed refusal 時由 13 升契約。
- Portable node 用 `entryID` 回查，不帶 `fileURL`。
- 沒有新的 Swift 或 npm dependency，`Package.resolved` 沒有變更。

### 建議 Decision Log

請 integrator 寫入 `docs/decision-log.md`。本 lane 沒有改那個檔。

2026-10-08。將 WorkspaceKit 的純檔案樹、顯示用 byte path 與詞法相對路徑抽到 WorkspaceCore，依賴只有 Foundation 與 MarkdownCore。Mac `WorkspaceFileTree.reconcile(previous:snapshot:options:)` 與 `WorkspaceItemMutationExpectation` 留在 WorkspaceKit，以後者的 entry index 附回每個 node。Root 與 generation 守衛只放在 `WorkspaceSnapshotReconciler`。`WorkspaceRelativePath` 拒絕而不改寫；路徑相等使用 UTF-8 bytes，因為 Swift `String` 相等是 canonical。未採用的做法：把 Darwin device／inode 放進 core、用 canonical string 當路徑 key、讓 Mac `Entry.normalized` 去掉開頭 `/`、把 workspace UUID 放進 display key。最後一項會讓拿掉 root 守衛之後，跨 root 測試仍然通過。

### Claude review

```sh
git diff --stat 642cb212703220409874a2741c5adbfb8c80fe8a...HEAD
rg -n "Darwin|inode|mutationExpectation|FileManager|resolvingSymlinks" Packages/WorkspaceCore/Sources
swift test --package-path Packages/WorkspaceCore
```

預期：sources 只有 `Contracts.swift` 的既有註解提到 Darwin；WorkspaceCore 是 25 tests、0 failures；Mac `reconcile` 沒有新增 root 或 generation 參數。

## 可直接貼給其他 LLM 的任務

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
