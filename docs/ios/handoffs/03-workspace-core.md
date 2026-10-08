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

尚未執行；本文件僅為並行開發 handoff，沒有產品實作或測試結果。

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
