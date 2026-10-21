# Lane 12 — iOS 建置、CI 與 unsigned IPA：交付摘要

> 2026-10-15 acceptance wiring：見 [acceptance-wiring-20261015.md](acceptance-wiring-20261015.md)。那次只接 `IOSAcceptance` scheme 與 admission。hosted smoke 1/1 只證明 scaffold 仍不可用。沒有新的 archive／IPA，也沒有 hosted PASS。
>
> 2026-10-13 review fixes 與新的 clean-head receipts：見 [review-fixes-20261013/README.md](review-fixes-20261013/README.md)。下列 2026-10-08 內容為歷史交付；不能授權新的 HEAD 或關閉 simulator／真機／product gates。

日期：2026-10-08。契約版本：IOS-C0-v1。**C0 已交付**（`ios-c0-v1` =
`642cb212703220409874a2741c5adbfb8c80fe8a`，13→12 交接 receipt 確認
`project.yml`／`Makefile`／`Scripts/ios`／`ios.yml` 歸 lane 12 獨占），
正式入口已實作並實跑通過。

## 狀態宣告

**四個固定入口全部 exit 0**：`ios-build`（sim Debug）、`ios-test`（12/12 named
tests，iPhone 17 Pro iOS 27 runtime）、`ios-archive`（device Release arm64）、
`ios-ipa`（unsigned IPA＋SHA-256＋nested signing report）。實跑證據索引見
[`build-run-index.md`](build-run-index.md)；binary 在 `/private/tmp/plainsong-ios-release/`。

## 交付格式

| 項目 | 值 |
|---|---|
| Branch | `phase3-ios-build-and-ipa` |
| Worktree | `/private/tmp/plainsong-ios-build-and-ipa` |
| Base SHA | `642cb21`（`ios-c0-v1`，13 公布）＋ lane evidence commit `39e522e` |
| Head SHA | `git rev-parse phase3-ios-build-and-ipa` |
| PR | **未開／未 merge**——maintainer 處理 |
| 實際修改路徑 | `project.yml`、`Makefile`、`Scripts/ios/**`、`.github/workflows/ios.yml`、`docs/ios/build-and-ipa.md`、`docs/ios/evidence/lane-12/**`、`docs/ios/handoffs/12-build-and-ipa.md` |
| 已實作介面 | `make ios-build`／`ios-test`／`ios-archive`／`ios-ipa`；`c0-*` bootstrap target 保留 |
| Named tests | 12/12 PASS（PlainsongIOSTests，named-tests.txt 留檔） |
| 已跑的檢查 | 四入口實跑、`bash -n` 全部、`py_compile`、`xcodegen generate`＋`-list`、IPA 解包 structural check、負向 probe N2/N3/N5、Mac `make build` PASS、`make -n test` 展開不變、`git diff --check` clean |
| 未跑／未過 | `make lint` **FAIL（pre-existing 產品碼 `redundantSendable` 等 7/609 檔，非本 lane 範圍）**；`make test` 完整跑（recipe 位元不變，Mac build 已驗證）；hosted ios.yml 未觸發 |

## 文件索引

- [`build-run-index.md`](build-run-index.md) — **實跑證據**（exit code、SHA-256、
  structural verification、負向 probe、Mac regression、關卡狀態）。
- [`toolchain-preflight.md`](toolchain-preflight.md) — 本機 inventory＋preflight gate
  （pre-C0 時零 simulator runtime；正式跑前 owner 已裝 iOS 27 runtime）。
- [`build-design.md`](build-design.md) — 四入口、固定鎖、unsigned 語意、metadata schema。
- [`test-plan.md`](test-plan.md) — 負向測試 N1–N12、關卡分列格式。
- [`wiring-requests.md`](wiring-requests.md) — 給 13 的凍結／確認項。
- [`drafts/`](drafts/) — pre-C0 draft（已平移為正式 `Scripts/ios/`，留作歷程）。

## 關卡分列

- **BUILD PASS** — 本地 build/test/archive/IPA 皆 exit 0，structural evidence 齊。
- **INSTALL OPEN** — unsigned IPA 不可安裝、未真機驗證；owner 重簽→安裝→啟動→
  Files 讀寫是獨立 owner gate，本 lane 不關。
- **Exact-head hosted** — `ios.yml` `workflow_dispatch` only，已提交未觸發，
  無 run ID 可報。
- **待 L3 review** — 簽名／IPA／平台隔離語意（handoff 指定）。

## 不做的事（依 handoff 邊界）

- 未改 `App/**`／`AppIOS/**`／package manifests／`ci.yml`／`Scripts/release.sh`／
  共享測試腳本／`.gitignore`／其他 lane 路徑。
- 不產生簽名、不保存 credentials／provisioning、不發布 IPA、不自行 merge、
  不 force-push、不改 owner checkout 或其他 worktree。
