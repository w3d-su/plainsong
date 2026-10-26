# Main completion integration — 2026-10-26

[PR #219](https://github.com/w3d-su/plainsong/pull/219), branch `codex/ios-main-finish-20261026`, directly targets `main` at `e09801309e855dce6ee903101ac2180e164daef2`.

## Source and scope

Only #217 squash `b28bf33691363b5084fc36a8c84e70dfa00d0901` and #218 squash `3de75ee278c552fb508bac7b36d16a6eb263f42d` were transplanted. Their successive parent trees matched the current main and intermediate candidate. The clean transplant `c5fc4f652205fc443321fe0463c0914720b262c7` was tree-identical to historical `b1380edc`; no divergent ancestry was merged and #209 was not repeated.

The final implementation is `565a7b15b47e66de9dc08d114e4dc117c033ebe1`, input fingerprint `3ac1cda78e689a2608c262edd0e766e12887f84fa9914405fed2f2ebad758218` (810 inputs). It additionally fixes the reviewed Recent downloading/offline single-file regression: preserve the still-current selected scope for Refresh/retry and report the existing typed feedback. Cancelled, superseded, revoked, unsupported and shutdown paths remain fenced. [Decision](../../../decisions/2026-10-26-ios-recent-pending-file-retry.md).

[Independent exact-source review](exact-source-review-565a7b15.md) and [preservation audit](preservation-final.json): 23/23 PASS. Frozen13/71 declarations, dependencies, Mac/Preview source and bundle, build/workflow policies and the owner checkout are preserved. The 125 main and 187 transplant required names remain; the final manifest requires 199. Claude's final review and maintainer merge remain separate.

## New execution evidence

| Complete lane | Passed/executed | Required names | Runner exit |
| --- | --- | --- | --- |
| modules | 566/566 | 199 | 0 |
| preview | 197/197 | 110 | 0 |
| preview-repeat | 197/197 | 110 | 0 |
| launch | 3/3 | 3 | 0 |
| launch-ipad | 3/3 | 3 | 0 |
| components | 29/29 | 29 | 0 |

All six lanes and Release share the exact implementation and fingerprint above. Both Preview runs are complete new executions, each including all 110 required names. No manual native-process or diagnostic-collector intervention occurred in these final lanes. Original readiness, JavaScript and per-case deadlines remain unchanged. [Source-bound receipt](native-receipt.json) preserves actual executed SHA and private raw locations; complete logs, DerivedData and xcresults remain in place.

The clean transplant's complete modules run passed 554/554. Only its higher-level sequence controller was then stopped to prevent obsolete follow-up lanes; that module runner completed normally. The tests-only negative head `b27c231795f33a5bda3c20ae9ea296468b6bc43e` executed all 566 cases: 558 passed, eight new regressions failed, zero skipped, native runner exit65 (outer make exit2). Its full failure is retained; it is not relabelled as a passing final-source run. Historical b138 modules diagnostic intervention and earlier failed publication kits stay unchanged.

Local Mac complete package/portable/sandbox regression and app build pass; exact counts and existing skips are in the receipt. The repo receipt keeps counts, skipped names, commands and raw hashes; the delivery kit retains the complete named summary. CI=1 is recorded for package tests only; the build-only lane has no timing acceptance. This is normal-load regression evidence with CI timing classification, not measured device performance acceptance. Tooling44/44 passes. Pinned SwiftFormat0.62.1 reports 0/1026 files needing format (two excluded files skipped); SwiftLint reports434 warnings/0 serious. Current publication-head CI is read separately from PR #219 and the final delivery kit; earlier-head CI does not substitute.

## Unsigned artifact and owner gates

`PlainsongIOS-565a7b15b47e.ipa`: 3,247,596 bytes; SHA-256 `ac66708d41a1b45d0c4736dc7933f43f18a0b0daf4c7b3a3b9bf719d125a860c`. [Independent actual ZIP audit](ipa-independent.json) verifies CRC, arm64 IOS/min26, iPhone+iPad families, UTI/document declarations, all nested unsigned code, resources and exact committed preview inventory. The delivery kit is assembled separately in this chat's artifact directory as `ios-main-finish-20261026` after publication-head CI and byte checks pass. Its publication includes checksums, source/publication input equivalence, a CI snapshot, Chinese installation/regression steps, public disposable fixtures and a blank owner-results form.

The new artifact has not been signed or installed on a physical device. Real Files/iCloud, physical Chinese IME/Undo, recovery/conflict/background acceptance, physical iPad, minimumOS26, VoiceOver/external keyboard and measured performance remain individually OPEN. Prior M0 iPhone14Pro/iOS27 owner-reported prerequisites retain their original scope; no repeat of the old Fixture/three-second test is requested. Simulator/native/CI/IPA structural PASS does not declare v1 accepted. No self-merge or force-push.
