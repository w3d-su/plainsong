# 06 — iOS 工作區存取、檔案樹與最近開啟

## 任務與智力需求

- **建議：L3 高階推理；lease／provider 接點由 L4 review。** File Provider availability、scope lifetime、root revocation 與 snapshot generations 會跨越非同步操作，錯誤可把舊工作區事件套到新工作區；不是單純寫 SwiftUI List。
- Branch：`phase3-ios-workspace-browser`。依 [總表](../README.md) 使用獨立 worktree。
- 目標：提供 Files／iCloud 的 in-place file／folder access、root-specific leases、bookmarks／recents、coordinated directory snapshots 與 workspace events。對 App lane 提供可顯示的 tree／loading／unavailable 狀態。
- 本 lane 是 service／models，不寫 App 的 file picker／sidebar。新文件 UI 由 App 發請求給 05 store；此 lane 不保存 document source，首版不做 rename／move／delete。

## 起跑條件與並行關係

1. 13 integrator 完成 C0：凍結 WorkspaceKitIOS manifest、`Contracts.swift`、doubles、workspace location／lease／coordination／resource-reader contracts 後起跑。
2. 依賴 03 WorkspaceCore。05 文件與 07 preview 可使用 C0 fake grants／readers 同時開發，不能自行建立第二份 access manager。
3. M0 尚未完成時可驗證 picker→grant→coordinated read prototypes；完整 provider wiring 須由 owner 關閉 M0 real-device Files／iCloud gates。

## Exclusive write paths

- `Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Access/**`
- `Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Workspace/**`
- `Packages/WorkspaceKitIOS/Tests/WorkspaceKitIOSTests/Access/**`
- `Packages/WorkspaceKitIOS/Tests/WorkspaceKitIOSTests/Workspace/**`
- 本 handoff 的 evidence section。

禁止修改 shared Package.swift／Contracts.swift、Documents／Recovery、AppIOS／UI、PreviewKit、Mac WorkspaceKit、all manifests／CI／build／agent.md／Decision Log。UISidebar／UIDocument writer／asset-policy validation 交對應 lane。

## Access／bookmark／coordination 契約

- 型別使用 `IOSWorkspaceGrant`、`IOSWorkspaceAccessLease`、`IOSWorkspaceAccessProviding`、`IOSCoordinatedFileAccess`、`IOSWorkspaceAssetWriting`；signature 與測試 doubles 以 C0 為準，不能自行新增競爭接口。
- Picker 使用者選擇到的 URL 由 C0 facade 接收。Grant 保留原 user-selected scoped resource；folder grants 只涵蓋該 root，single-file grants 只涵蓋該文件，不能把 parent directory URL 視作隱含 grant。
- Scope 為 retained lease，可被 document writer／scan／resource read 各自持有，開始／停止配對且最後一個使用者釋放後才 stop。Root switch 後既有 safe-drain 操作可保持自己的 lease，但不得發布到新的 workspace。
- `startAccessingSecurityScopedResource()` 回傳 false 的解讀必須依 URL provenance／實際可存取性處理；不要照抄 Mac helper 當作存取已成功，也不要把 app-container 非 scoped URL 一律判拒絕。所有真正 provider read／write 都進入有效 lease＋coordinated accessor。
- Bookmarks 採 iOS 支援的 Foundation options，由 implementation agent 依 current Apple docs 驗證。恢復需解析 stale／unavailable、重新取得 access、成功後 refresh；失效以「重新選擇」狀態處理，不假稱 recents 可用。
- Root-specific opaque provider resource ID 只當 identity；若 provider 未給穩定 ID，回傳明確 fallback／未知，不能使用 inode 或 URL string 假裝 File Provider authority。每次 grant restore／replacement 產生明確 generation。
- 提供 C0 coordination service，涵蓋 bounded read／snapshot／必要 namespace access、取消、availability errors；URL 只在 coordinated accessor 的有效時間使用。不要給下游一個裸 URL 再讓其繞過 coordination。
- Preview 注入的 resource reader 在此 lane 實作：只返回 coordinated data／metadata／root generation，持有 lease 到 read 完成。路徑、suffix／type／size／symlink 與 token 授權仍由 07 PreviewKit 驗證；reader 不能用「成功讀到 bytes」替代 preview policy。
- 為 09 image lane 提供 `IOSWorkspaceAssetWriting`：具明確 folder grant 才能 stage／publish image，回傳 `IOSStagedImageAsset`，以 operation ID commit／rollback。僅清理同 operation 自己擁有的 artifact，不清別次 insertion／existing files；source edit 由 09 經 04 guarded editor 執行，此 lane 不寫 Markdown source。單文件 grant 不足時要求明確 parent／folder picker 或拒絕，不暗自授權兄弟檔。

## Snapshot／events／recents 行為

- 在 provider coordination 範圍內 enumerates directory；不把 FSEvents port 到 iOS。以 directory presentation／provider changes、foreground refresh 與使用者 refresh 補足事件來源，明確承認 provider notification 不等於無延遲同步。
- Tree refresh 是 root identity＋generation＋request token 的不可變 snapshot，列出 file kind、relative path、opaque identity、availability、可用 metadata；不下載所有檔案只為畫 tree。
- 過時 refresh／root close／newer request cancellation 必須丟棄；event burst coalesce，成功 reconciliation 保留 expansion／selection。不會因一次 offline scan 把完整 tree 清空或撤銷仍可編輯 session。
- 未下載／離線／read-only／removed 表示為 typed availability；可操作的文件才發 open request，實際 document open／download progress 由 05 發布，不靠 scan 的舊狀態保證可寫。
- External move／delete 只回報 scoped workspace events；05 store 再依 provider identity 做文件保護，不能直接改 session URL／source 或清除 recovery。
- Recents 儲存最近成功開啟的 file／folder grant、display name、kind、bookmark、timestamp；依 root identity 去重、保留最後 10 筆，對齊現有 `RecentItemStore.maximumItems` 預設。Unavailable entry 保留「重新選擇／移除紀錄」操作，不能移除原文件。
- 單文件授權不足：事件回報 requires-folder-access，讓 App 顯示 directory picker；沒有使用者 grant 之前不試讀 sibling assets，也不 copy-in 假冒 in-place 工作區。

## 測試與驗收

- Deterministic fake scopes：兩個 consumers 共用 root → 中途 release 一個 → 未 stop；取消 scan／讀圖／開檔仍配對 release；root switch→late completion 不得發布。
- Bookmark cases：fresh／stale／denied／removed／provider offline；restore 後 root replacement 或同名不同 resource，old token 不能繼續授權。
- Snapshot fixtures：預設與 show-all、hidden ancestors、NFC／NFD、provider duplicate IDs、無 stable ID、未下載檔。Foreground／manual refresh 能更新 tree 並保留合法 selection。
- Coordination tests：確認 UIDocument-owned operations 沒被第二次 nested coordination；單文件 read 不能開 sibling，preview reader 不越 root，provider read failure 不回傳空 Data 假成功。
- Asset publication tests：failed publish／stale source edit 的 rollback 只移除 matching operation artifact；另一 operation 在相同目錄成功的 image 與 existing asset 完整保留。
- Negative probes：移除 generation guard、release lease 過早、把 denied bookmarks 當 successful、將 scope 擴大到 parent，對應 tests 必須失敗。
- 真機 owner scripts：Files local folder、iCloud folder／placeholder、Airplane Mode、Mac move／delete／修改、background resume、permission reselect。Third-party provider 支援不能只凭 doubles 宣告；先記錄測試過的 provider。

## Stop gates 與 PR evidence

- 假 in-place import、root authority 不明、檔案樹 refresh 會影響未存內容、provider notice 繞過 05 conflict arbitration：停止產品接線並保留 reproduction。
- PR 列 SHA／contract version／path ownership、scope lifetime 與 cancellation 證據、typed failure cases、real provider matrix、executed named tests、未關 manual gates、給 integrator 的 global doc／manifest patch 建議。
- 供 05／07 整合時附 provider revision 與 compatible contract version，不能只說「API 已做完」。不 merge／force-push；Claude 可從 tests 檢查 scope 及根目錄邊界。

## Evidence（由執行者填寫）

尚未執行；bookmarks／iCloud／provider notification 行為仍需實作與真機驗證。

## 可直接貼給其他 LLM 的任務

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
