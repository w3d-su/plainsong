# iOS production composition evidence — 2026-10-23

This is the minimum formal-App Files → native source edit → real preview → save → reopen milestone. It composes the existing providers; it does not declare v1 acceptance complete. The pre-composition owner reports remain in [the M0 packet](../m0/owner-retest-20261023/README.md).

## Source-bound native result

The public runner logic, with only its isolated checkout and reused derived-data path changed, completed on clean `c18e41ace508`: **430 executed, 430 passed, zero failures/skips**, including all 63 required names. Its six compiled test images passed admission, four resource paths and complete preview-directory byte parity. [Receipt and original log digests](native-module-c18e41a.json).

Five app-hosted workflows use the production factory, actual UIDocument store, native editor, Files provider and packaged WKWebView preview. They cover edit/render/save/re-pick, folder row switching under one grant, single-file sibling refusal, New File collision avoidance and initial observer publication. This is simulator evidence, not iCloud or physical-device acceptance. The 600-second post-case diagnostic collection completed with runner exit 0; it is retained, not hidden as test execution time.

## Reproduction and retained failures

The original `3b00cec` full run built all six images but failed the first workflow at immediate re-pick with `closeFailed`. Its retained writer correctly blocked the four following workflows. These are cascading admission failures, not five independently diagnosed I/O defects. The original run remains at `/private/tmp/plainsong-ios-production-20261023/evidence/3b00cecd5971-test-20261023-144803-38439`.

A controlled old-code run added phase-only diagnostics and four explicitly parked external-read regressions. All four regressions failed (seven assertions); the real-provider workflow passed on that attempt and showed no pending observation at close. The deterministic cases establish a premature-retention race, but do not prove which barrier fired in the earlier uninstrumented failure. The fix waits for already-issued reads after the writer queue drains, then retains every dirty, conflict, proposal, access and post-close revision check. The four regressions and all five workflows passed on `c18e41a`.

Old lifecycle SHA-256: `a9fd7e6e3a68e65938974f72b13a9828c222ca66a96c9df0cfbfefe627134d81`.
Diagnostic old lifecycle: `d307b2cc0ea61dc5f86ed98054a2ef8106e2b41f42d5e0e07497ec4e0bf0f9d1`.
Fixed lifecycle: `0ba7f2b62a5450875ea8f02724543497f82c83012835f4dee8f2dae6f42951e9`.
The original, diagnostic and fixed files, source manifest and complete negative results remain under `/private/tmp/plainsong-ios-production-20261023/close-negative-control` and its parent. Temporary diagnostic edits were restored before the passing run. Three earlier compile failures also remain under that root's `evidence/` directory.

## Preview and final-candidate boundaries

The old full-preview stall, independent first-controller pass, later readiness failure and instrumented run (180 passed, one failed, two opt-in skips) remain under `/private/tmp/plainsong-ios-pr191-20261023` and `/private/tmp/plainsong-preview-diagnostics-eb4e77-20261023`. The instrumented cancellation case failed before creating its cancellation task; it does not demonstrate cancellation logic failure. Kitchen-sink passed in that run. The relationship between `InvalidTransition` and navigation readiness remains unproven.

The candidate removes borrowed idle XCTestCase helpers and registers deterministic WebView cleanup on the executing case. It excludes only the opt-in paired benchmark file from the iOS functional plan; SwiftPM still exposes those probes. All functional assertions, required names, deadlines and the zero-skip gate remain. A passing earlier source cannot substitute for the final candidate's full-preview result.

The delivered kit's `candidate-receipt.json` records its final source, complete preview result, exact-head CI and unsigned Release IPA digest separately from this historical module result. The [launch smoke contract](../validation/production-launch-smoke-20261023.md) is also separate; source changes do not claim an executed UI smoke.

## Open acceptance

The new composed artifact needs its own owner re-sign/install and real-device acceptance. Physical iPad, minimum OS26, Files/iCloud behavior, IME/Undo, background save, VoiceOver, hardware keyboard and performance remain open for that artifact. Relaunch recovery-list UI and conflict Save a Copy UI are not yet connected. No signed artifact hash or new device result is inferred from the earlier M0 reports. WYSIWYG, cross-file search, Replace All, export, multiwindow and TestFlight are outside this minimum milestone.
