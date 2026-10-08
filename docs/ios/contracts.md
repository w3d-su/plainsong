# IOS-C0-v1 — 共用契約與變更規則

日期：2026-10-08。狀態：**C0 宣告已落實；provider／完整 App 尚未實作**。IOS-C0-v1 的唯一 Swift declarations 及所有權見 §9；基準／驗證狀態見 integration-ledger.md。初次凍結同時具體化 binding identity、focus、reload acknowledgement 與 observer ownership，不能將 specification 中的省略當成另一個可自行實作的 API。此後單一欄位、隔離或回傳語意變更都須由 13 升契約版本並通知所有 consumer。

## 1. 層次與 manifest

固定依賴：

- `MarkdownCore`：Foundation／Combine、Yams；原始碼與 pure edit logic，沒有 UIKit／AppKit／WebKit。
- `SyntaxKit` → MarkdownCore + 既有 pinned tree-sitter／grammars；沒有 UI attributed text。
- `WorkspaceCore` → MarkdownCore；純模型／路徑，不做檔案 I/O，不匯入 Darwin／CoreServices。
- `EditorKitIOS` → MarkdownCore + SyntaxKit；UIKit／SwiftUI 的 source engine。
- `WorkspaceKitIOS` → MarkdownCore + WorkspaceCore + PreviewKitContracts；UIKit `UIDocument`／Foundation coordination；06 只依賴 preview 的純 reader/checker product，不反向依賴 UIKit/WebKit implementation。
- `PreviewKitContracts` → MarkdownCore；C0 的 portable declarations，沒有 AppKit/UIKit/WebKit。
- `PreviewKit` → MarkdownCore + PreviewKitContracts；WebKit + 每平台 view wrapper。它不反向依賴 WorkspaceKitIOS；資源讀取透過注入。
- `AppIOS` → 上述 provider；authoring／images／views 消費介面，只有 13 擁有 production composition。
- Mac 的 EditorKit／WorkspaceKit 依新純套件；Mac UI、FS authority／physical identity 繼續留在 Mac adapter。

沿用現有 compiler language mode／strict concurrency，C0 不做 Swift 6 migration 或依賴升級。SPM 的最低 iOS 使用 `.iOS("26.0")` 宣告，保留原本 macOS 14；iOS-only target 不加入 Mac `swift test` loop。各 manifest 依 README 的所有權交接。`make test-portable-core` 單獨跑 SyntaxKit/WorkspaceCore 的 Mac pure regression；原 Mac package loop 保持四個既有 packages，UIKit-only packages 不在其中。

## 2. 文件、selection、write authority（13 宣告，04／05 實作）

以下純值放在 MarkdownCore 的新增 `IOSDocumentContracts.swift`；初版不修改既有 Mac session API。

| 型別 | 必備欄位／語意 |
|---|---|
| `IOSDocumentIdentity` | `rawValue: UUID`；一個開啟 instance 的不透明身分，不由文字／path hash 推導 |
| `IOSDocumentRevision` | `documentID: IOSDocumentIdentity`、`version: Int`；version 對應 DocumentSession，兩欄都要相等 |

EditorKitIOS 的 frozen `Contracts.swift`（13 宣告）提供：

| 型別 | 必備欄位／語意 |
|---|---|
| `IOSSourceEditorSnapshot` | `bindingID: UUID`、`isFocused: Bool`、`revision`、現有 `DocumentSnapshot`、UTF-16 `selection`／`visibleRange`、`selectionGeneration: UInt64`、`accessGeneration: UInt64`、`hasMarkedText`、`canWrite` |
| `IOSAuthorizedEdit` | `bindingID: UUID`、`baseRevision`、`selectionGeneration`、`accessGeneration`、現有 `MarkdownEditResult`、`undoActionName: String`；proposal 不可直接發布 session 文字 |
| `IOSEditOutcome` | `.applied(IOSDocumentRevision)` 或 `.refused(IOSEditRefusal)` |
| `IOSEditRefusal` | binding／document／source changed、selection changed、access changed、marked text、read only、invalid range、busy、not focused、unavailable；失敗零修改／零 undo／零 selection side effect |

固定最小 writer surface：

```swift
@MainActor
public protocol IOSSourceEditorControlling: AnyObject {
    func captureSnapshot() -> IOSSourceEditorSnapshot?
    func apply(_ edit: IOSAuthorizedEdit) -> IOSEditOutcome
    func reveal(_ range: NSRange, expected: IOSDocumentRevision) -> Bool
    func undo()
    func redo()
}
```

`apply` 是同步 MainActor final check + 單次 native insertion，不在驗證與寫入中間 await。04 在原生 writer 完成後發布 session；08／09／10 不可先改 `DocumentSession.text`。reveal 只選取／捲動並遞增 selection generation，不製造 source edit；marked text 時拒絕侵入式動作。generation 防止 A→B→A 被錯認為未改動。`bindingID` 每次 attach 由 13 指派新的 UUID；舊安裝的 proposal 即使 document/version/generation 恰好相同也必須拒絕。04 同步驗證 scene command focus ownership；`isFocused` 不是單純 UITextView.isFirstResponder。13 經帶 expected document/binding 的 `setCommandFocus`／`updateCommandFocus` 維持 route，owned authoring form 可保留原 editor route；切到別的文件/scene 則失效，不能改投另一個 editor。

04 實作 document attach／detach、snapshot/event observation 的 adapter；13 在 C0 同一個 frozen file 定義 consumer 需要的 callback 名称。觀察者只消費不可變 snapshot，不能繞過 writer。05 的 read-only／conflict／grant 失效必須先更新 access generation；所有 toolbar／image／replace 寫入都依此拒絕。

## 3. 共用 syntax（02 provider，04 consumer）

C0 在 SyntaxKit 宣告以下表面，02 落實 parser／純 fold extraction：

- `MarkdownSyntaxToken`：保留 baseline parser 的全部 `Kind` 與絕對 UTF-16 `range: NSRange`。02 移動宣告而非複製另一個 enum；Mac 與 UIKit 顏色／font mapping 留各平台。
- `SyntaxRequest`：`requestID: UUID`、`version: Int`、`source: String`、`fileKind: FileKind`、`visibleRange: NSRange`。
- `SyntaxResult`：相同 `requestID`／`version`、`coveredRange: NSRange`、`tokens: [MarkdownSyntaxToken]`。
- `MarkdownSyntaxTokenizing: Sendable`：`func tokens(for request: SyntaxRequest) async throws -> SyntaxResult`。

provider 擁有 parser 隔離，off-main parse；consumer 還要檢查自己的 document identity／viewport／request generation。requestID／version 並不是 file authority。取消後已產生的结果仍須丟棄。Mac fold API 必須保留全既有 pure model／parser extension 語意及 tests；不能只抽 source tokens 然後讓 WYSIWYG 損壞。

## 4. 工作區 model 與 grant（03 values，06 provider）

WorkspaceCore 的 frozen provider models 使用以下名稱：

- `IOSWorkspaceIdentity(rawValue: UUID)`：一次 root authority 的不透明身分。
- `IOSFileLocation`：`workspaceID`、`accessGeneration`、`relativePath`、`fileURL`、可選的 opaque `resourceID`。單檔 grant 的 relativePath 僅代表該檔；不授權 parent／siblings。
- `IOSWorkspaceEntry`／`IOSWorkspaceSnapshot`：entry opaque ID、root-relative path、kind、children／flat snapshot；snapshot 帶 workspaceID 與 generation。與現有 Mac tree 相容的資料抽取由 03 決定到最小 adapter，但不得讓 iOS 誤用 Mac inode／device authority。

保留 path 的原始 Unicode／byte 拼法；拒絕 absolute path、越界 parent traversal 與 root 外 symlink。展示字串／Foundation canonical equality 不可以取代路徑授權。未知 provider 狀態不能直接視為檔案不存在。

WorkspaceKitIOS frozen `Contracts.swift` 中：

- `IOSWorkspaceGrant`：workspaceID、rootURL、accessGeneration、singleFile／directory scope；僅由 06 授出。
- `IOSWorkspaceAccessLease`：grant-bound、可持有至 async operation 完成，idempotent release；start／stop 正確配對。
- `IOSWorkspaceAccessProviding`：open／restore grant、acquire lease、invalidate generation、觀察 root snapshot。bookmark opaque data 不寫入 logs／repository；recent 預設 10 筆。
- `IOSCoordinatedFileAccess`：在指定 location + lease 下讀取、create new leaf、取得 directory snapshot／外部事件的 async seam。成功回傳包含實際協調後位置與 generation；操作前後驗證 grant，失效取消／拒絕。05 的既有文件儲存由 UIDocument 擔任唯一 writer，不透過另一個通用 overwrite API。

06 同時實作 PreviewKit 的 `PreviewAssetReading` adapter 與 image staging writer。consumer 不能自行 new grant、只檢查字串 prefix，或以 copy-to-app-container 冒充 in-place editing。File Provider 無法證明安全讀寫時回傳 typed failure，保留原稿。

## 5. 文件 persistence（05 provider）

`@MainActor IOSDocumentStore` 是 UIDocument-backed 服務，不依賴 EditorKitIOS concrete text view。最小能力為 `open(location)`、`save(identity)`、`close(identity)`、`saveCopy(identity,destination)`、`resolveExternal(identity,choice)`，以及 snapshot／state／events。13 在 C0 為這些能力落實唯一 Swift declaration，05 不再 invent 第二個 FileDocument store。

固定狀態／事件名稱：`IOSDocumentState`、`IOSDocumentEvent`、`IOSSaveAcknowledgement`。必備語意：

- state 區分 opening／ready／saving／conflict／unavailable／closed，公開可寫狀態與 access generation；waiting/download failure 是 failure／loading，不能用空白 source 頂替。
- save acknowledgement 帶 document identity、captured saved version／text、location／operation ID；不可只有 Bool 成功。
- 每個實際 resource 唯一序列 writer；同檔重複 open 由 store registry 收斂，不能讓兩個 UUID writer 各自覆寫。
- save 完成後先驗 document／location／operation 順序，再用既有 `rebaseSavedText(to:)` 更新保存基準。**對舊快照呼叫 `markSaved(text:url:)` 會改 live source，禁止。**
- 外部 clean reload 只在 capture revision 仍有效且 native 非 composing 時套用；dirty conflict 先保存本地 recovery snapshot、阻擋 overwrite，顯示 reload／save-copy 選項。
- recovery 在 app-private storage 以 operation/document IDs 定位，記錄 source、identity、captured version、原因。儲存／授權失敗不丟 dirty session；background flush 是 best effort，已持久化 recovery 才可聲稱可恢復。

05 直接依賴 MarkdownCore + WorkspaceCore + 06 seams；04 attach 同一個 DocumentSession。source 與 dirty truth 唯一份，不同 module 不建立 shadow editable String。

## 6. 預覽資源介面（07 宣告／消費，06 provider）

C0 reserved `Packages/PreviewKit/Sources/PreviewKit/PreviewAssetReading.swift`，13 凍結宣告；07 可新增 typed request/result helpers，但不能改 frozen表面而不升契約。

```swift
public protocol PreviewAssetReading: Sendable {
    func read(_ request: PreviewAssetReadRequest) async throws -> PreviewAssetReadResult
}
```

request 帶 requestID、resolved URL、allowedRoot URL、opaque root token、grant identity/access generation、10 MiB byte limit；result 原樣回傳 requestID 及完整 access context，另帶實際協調 URL、bytes；不能只比較 generation 而忘記 root/grant identity。UIKit／WorkspaceKitIOS 具體型別不滲進 PreviewKit。Mac default reader 維持既有 policy；App 注入 06 reader。

07 的 handler 保留 MIME allowlist（PNG／JPEG／GIF／WebP）、size、path/symlink containment、CSP／remote-image policy，並在 read 後與每次發送前檢查 stopped task、current root token、grant generation。request A 開始後切到 root B，A bytes 不得送進 B。07 定義 checker seam，使不依賴 WorkspaceKitIOS 的 consumer 能詢問 grant 是否仍有效；C0 同時凍結該 checker declaration。

保留 bridge protocol 8 的既有 render／stale DOM／checkbox revision protection；無必要不改 wire shape。若必須改，07 先向 13 提案，Swift／TS／protocol bump／generated bundle 在同一已指定 ownership 的 PR 內完成。

## 7. Authoring 與圖片（08／09 consumer）

08 擁有 `IOSAuthoringAction` descriptors（format／find／replace）、frontmatter／find UI state；10 安裝它們到 toolbar／目前 scene 的鍵盤命令。04 只擁有原生 typing behaviors 與 Undo／Redo routing。commands 不作用到未聚焦或另一文件的 editor。

Frontmatter／Replace 一律從當下 immutable snapshot 使用既有 pure planners 準備 `MarkdownEditResult`，交給 `IOSSourceEditorControlling.apply`。Find 是現有 literal semantics，匹配範圍 UTF-16；沒有 regex 或 Replace All。Malformed YAML 不自動重寫。

06 提供 `IOSWorkspaceAssetWriting`，09 消費。`IOSStagedImageAsset` 有 operation ID、target location、relative path、owned-file identity、grant generation 與 commit／rollback token。此處 staged 指「檔案已保存、仍由 operation 擁有」：回傳的 relativePath 必須已指向成功持久化的最終 image leaf。commit 只終結／轉移 ownership，不得把實際 image publication 延到 source insertion 之後。

固定交易：capture editor → 用明確 directory grant 協調保存唯一 asset → 驗證 capture/context → 單次 native source insertion → commit asset ownership。source refusal／cancel／grant change 呼叫 rollback，只刪該 operation 可證明擁有的 leaf；cleanup indeterminate 留 receipt，不刪其他資產。不能先插 Markdown 再寫圖片，也不能把成功保存資產當作成功插入 source。

## 8. App 接線、測試與變更

10 UI 只需要 editor/doc/workspace/preview capability facade；mock factories 僅在 preview／test support。13 擁有 `AppIOS/Composition` production factories 及 scene state。12 擁有 target／resource wiring。11 的 tests 消費同一契約，不能擴張 API 來繞過拒絕路徑。

C0 要列出每個 protocol 的 actor、async／sync、取消、typed errors、identity/generation、observer ownership，並使用兩個獨立 fake consumer 編譯確認；尚無 provider 的能力明確 unavailable，不能回傳假成功。

任何欄位／隔離／authority／回傳語意變更：consumer 提交 diff + failure case 給 13 → 13 更新 frozen declarations／本檔與 Decision Log → 公布新 IOS_BASE_SHA → 所有相關線 additive merge 該基準。不各自升版本，不 force-push，不讓交付包帶兩套同名介面。


## 9. C0 唯一宣告索引與精確 seams

以下來源是 IOS-C0-v1 的唯一 Swift declaration；表內方法的完整參數／payload／initializer 以連結中的宣告為準。每個 public model 是 immutable Sendable value（session handles、binding 和 observation token 留 MainActor），range 均為完整來源 UTF-16。Swift 5 mode 的 `throws` 並非 typed-throws syntax，下表約束 provider 實際可拋出的錯誤類型。

| Protocol / facade | 隔離與呼叫 | 失敗、取消、observer ownership | 唯一來源 |
|---|---|---|---|
| `IOSObservation` | MainActor；同步 cancel | subscriber 保留 token；切檔/detach 前 idempotent cancel，後續 callback 已被 fence | [MarkdownCore](../../Packages/MarkdownCore/Sources/MarkdownCore/IOSDocumentContracts.swift) |
| `MarkdownSyntaxTokenizing` | Sendable provider；async tokens | SyntaxFailure / CancellationError；parser off-main 串行；consumer 對 requestID/revision/viewport 重驗 | [SyntaxKit](../../Packages/SyntaxKit/Sources/SyntaxKit/Contracts.swift) |
| `IOSSourceEditorControlling` | MainActor；capture/apply/reveal/undo/redo 全同步 | IOSEditOutcome / IOSEditRefusal；apply 最後檢查與 native insertion 中间不 await，拒絕零效果 | [EditorKitIOS](../../Packages/EditorKitIOS/Sources/EditorKitIOS/Contracts.swift) |
| `IOSSourceEditorBinding` | MainActor；attach/detach/updateAccess/updateCommandFocus/installExternalReload/observe | bindingID 每次安裝換新；detach/updateAccess/updateCommandFocus 也比對 expected binding；immutable snapshot event；subscriber owns token；reload deferred 保留舊 source/Undo | [EditorKitIOS](../../Packages/EditorKitIOS/Sources/EditorKitIOS/Contracts.swift) |
| `IOSWorkspaceAccessLease` | MainActor + Sendable reference；grant/isReleased/release 同步 | operation 持有至 provider safe drain；release 只釋放自己、可重複呼叫 | [WorkspaceKitIOS access](../../Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Contracts.swift) |
| `IOSWorkspaceAccessProviding` | MainActor；open/restore/refresh async；acquire/invalidate/snapshot/observe 同步 | IOSWorkspaceFailure / CancellationError；invalidate 先同步提升 generation；subscriber owns token | 同上 |
| `IOSCoordinatedFileAccess` | Sendable provider；read/createNewLeaf/directorySnapshot/events async | IOSWorkspaceFailure / CancellationError；before/after lease/root/generation validation；events stream termination 只取消觀察 | 同上 |
| `IOSDocumentStore` | MainActor；open/create/save/close/saveCopy/resolveExternal/flush async；state/snapshot/observe/acknowledgeExternalReload 同步 | IOSDocumentFailure / CancellationError；store retains session/lease through safe drain；immutable events；subscriber owns token | [Document contracts](../../Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/DocumentContracts.swift) |
| `IOSWorkspaceAssetWriting` | Sendable provider；stage/validate/commit/rollback async | stage 拋 IOSAssetStageFailure / CancellationError，validate 拋 IOSWorkspaceFailure / CancellationError；terminal action safe-drain、idempotent，回 committed/removed 或 retained receipt | [Image contracts](../../Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/ImageContracts.swift) |
| `PreviewAssetReading` | Sendable provider；async read | PreviewAssetReadFailure / CancellationError；06 持 lease 至 read 完成；result 帶實際協調 URL 與原 access context | [Preview reader](../../Packages/PreviewKit/Sources/PreviewKit/PreviewAssetReading.swift) |
| `PreviewAssetAccessChecking` | MainActor；isCurrent 同步 | 07 在每次 callback 前檢查 rootToken/grantIdentity/generation；checker 不得自行授權 | 同上 |
| `IOSPreviewControlling` | MainActor；render/setRemoteImagesAllowed/scrollToLine/invalidate/observe 同步 | immutable events；subscriber owns token；nil assetAccess 禁用 sibling reads | [Preview facade](../../Packages/PreviewKit/Sources/PreviewKit/PreviewContracts.swift) |
| `IOSAppSceneControlling` | MainActor；open/create/save/resolve/flush async；snapshot/capabilities/observe 同步 | 傳遞 document/access typed failures；state 沒有 shadow source；subscriber owns token | [App state](../../AppIOS/State/Contracts.swift) |
| `IOSAuthoringActionProviding` | MainActor；actions/isEnabled/perform 同步 | 08 建立 descriptors/handlers，10 安裝；04 最後仍 guard；sheet capture 不改投 current editor | [Feature seams](../../AppIOS/State/FeatureContracts.swift) |
| `IOSImageInsertionControlling` | MainActor；captureContext/cancel 同步，insert async | picker 前 capture；outcome 區分 inserted/refused/failed/retained/cancelled；source 拒絕不能當圖片插入成功 | 同上 |

`IOSDocumentReloadProposal` 包含 operationID、capturedRevision、accessGeneration、external source/fileKind/fileURL/precomputed statistics。05 發 `externalReloadRequested`，13 在同一 MainActor turn 呼叫 04 `installExternalReload`，再同步 05 `acknowledgeExternalReload`；中間不 await。composing/busy 回 deferred；過期 revision/root/operation 拒絕。只有已 guard 的 external reconciliation 能安裝來源，沒有新 user edit/Undo；save completion 永遠不使用這條路徑。

`IOSSaveAcknowledgement.revision` 是 captured document/version、`savedText` 是真正持久化的 bytes，location 帶 workspace/generation，operationID 供 store 排序。`saveCopy` receipt 指向 destination，不能拿來標記 original clean。只有 05 驗完原 resource、generation、operation order 後可用 `rebaseSavedText(to:)` 推進原保存基準；不以 receipt 到達時間判斷 live source。

`IOSImageAssetRequest.destination` 是 Markdown document location。06 在 directory grant 中保存 document-parent-relative assets；`IOSStagedImageAsset.targetLocation` 是 root-relative I/O descriptor，`relativePath` 是已持久化 image leaf 相對 Markdown parent 的插入字串。stage return 前圖片必須存在，commit 只轉移 ownership；unknown cleanup 保留 typed receipt。

### Frozen files（永久由 13 寫）

- MarkdownCore `IOSDocumentContracts.swift` 與其 contract regression tests。
- SyntaxKit `Contracts.swift`、`MarkdownSyntaxToken.swift`；Mac 的 token compatibility alias 交 02。
- WorkspaceCore `Contracts.swift`；03 新增 builder/path/adapters，不能改這個 frozen surface。
- EditorKitIOS `Contracts.swift`。
- WorkspaceKitIOS `Contracts.swift`、`DocumentContracts.swift`、`ImageContracts.swift`；`Tests/WorkspaceKitIOSTests/Contracts/**` 是 C0 seam tests，05/06 各自的測試仍在 Documents/Recovery 和 Access/Workspace。
- PreviewKit `PreviewAssetReading.swift`、`PreviewContracts.swift`、`PreviewContractExports.swift`（純 re-export）。C0 App 使用 `PreviewKitContracts` product；07 port 真實 PreviewKit 後，由 12 改正式 target dependency。
- AppIOS State/FeatureContracts、App/Composition、AppIOSTests/Integration，以及中央 ledger/contract docs。

C0 沒有 parser、UIDocument、grant、資源或圖片的成功 provider。App production composition 只提供 nil capabilities；private doubles 全部在 tests。C0 source directories 預先保留，SwiftPM default target 和 XcodeGen recursive App/AppIOSTests source rules 會自動納入 future implementation/tests；contract product 僅編譯已指定的 frozen files。


中央 architecture regression `EditorReplaceLayeringTests.swift` 在 C0 由 13 獨占維護；既有 test 明示 later approved dependency PR 應和 Decision Log 一起更新精確清單。C0 納入四個新 manifests、兩個 iOS targets 與 scheme tests，保留 strict equality、全部第三方 pins、npm inventory、Replace mutation/import 禁令；另驗 iOS scaffold 不連結 Mac-only providers、pure packages 沒有 UI imports。02/12 需要後續架構清單修訂時提交給 13，不自行改這個中央 gate。


stage 失敗若仍可能留下已持久化 leaf，必須回 `IOSAssetStageFailure.retained(receipt)` 或返回 staged asset 供 caller terminal cleanup；只在沒有 operation-owned leaf 留下時才能 throw CancellationError。source accepted 後的 image outcome 為 `inserted(revision, ownership: IOSAssetCommitOutcome)`，因此 commit ownership retained 不會被 UI 誤認為 source 未插入，更不能在這時 rollback 已被 source 引用的圖片。source 未插入且 cleanup indeterminate 才用 `IOSImageInsertionOutcome.retained`。


Lane 08 的 #155 dependency request 已由 C0 接受：`IOSAuthoringAction` 包含穩定 action id、title、accessibilityLabel、可空 keyboardInput、純值 modifiers 和 `placement`（toolbar / toolbarGroup(String) / formatMenu / find）；沒有 UIKit key-command 安裝行為。08 填 descriptors/handlers，10 安裝一次。`PlainsongIOSTests` hosted target 遞迴納入 `AppIOSTests/**`，`PlainsongIOS` 遞迴納入 `AppIOS/**`；08 不必改 global manifest 或新增 planner API。


C0 `PlainsongIOS` scheme 選取 12 個 contract smoke cases：App 兩個獨立 consumers/不可用 composition/preview resource（6），MarkdownCore IOSDocumentContractTests（2），SyntaxKit、WorkspaceCore、EditorKitIOS、WorkspaceKitIOS Contracts 各 1。整個 test target 仍編譯；既有 MarkdownCore fixture/performance tests 在 Mac `make test` 全跑，C0 iOS smoke 不執行依赖 Mac source-file path 的 unrelated fixture case。12/11 正式 iOS 驗收另提供實際 bundled fixtures，不得把這個 C0 smoke 改稱完整驗收。


05 的 `state(for:)` / `IOSDocumentEvent.stateChanged` 可在尚無 source 的 opening/unavailable 階段發布狀態；`snapshot(for:)` 仍回 nil，`IOSAppSceneSnapshot.documentState` 表達 loading/failure。不能為了產生 snapshot/event 先建立空白 DocumentSession；真實來源成功開啟後才提供 handle/DocumentSnapshot。
