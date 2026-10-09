# lane-12 drafts — 交接前設計稿

這裡的 `Scripts/ios/**`、`github/workflows/ios.yml`、`Makefile.snippet`、
`project-yml.snippet.yml` 是 **C0／13→12 交接前的設計 draft**，不是生效檔案：
全域 manifest／Scripts/ios／ios.yml 在 bootstrap 期間屬 13，交接 commit 後才由
lane-12 平移到正式路徑（平移時以 C0 的實際 target／package 名稱校準，見
`../wiring-requests.md`）。

已驗證：`bash -n` 全部 .sh、`python3 -m py_compile` resource preflight（2026-10-08）。
未驗證：ios.yml 的 actionlint／runner image 標籤、xcresulttool 子命令旗標、
真實 xcodebuild 執行（無 iOS target 前無法實跑）。
