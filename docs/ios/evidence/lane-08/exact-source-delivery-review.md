# Lane 08 async delivery follow-up — 2026-10-13

> Historical raw evidence and replay files referenced below are preserved at `e20162e5`. See the [archive index and restoration instructions](../README.md); run historical local-path commands from that restored checkout.

Source commit: `04015de35b3467dbc1074207531af50cf7a34941` (parent `76af905fe7fc61d9f78869ff10b629f729dd4a1a`). Assigned isolated worktree: `/Users/davis._.su/.codex/worktrees/ios-review-authoring/blogeditor`, branch `codex/ios-authoring-review-fixes`.

The earlier [Oct9 receipt](acceptance-review-fixes.md) and its 93 executed simulator cases remain historical evidence for `76af905`; they are unchanged. This follow-up fixes one additional acceptance gap: an async Find scan must still match the captured binding, document identity/revision, and exact raw UTF-16 source before delivery. A same-revision source change no longer becomes a newly accepted context for old match ranges.

Two new cases park delivery, change source while retaining revision, then deliver the old result. They assert no accepted session/context, no reveal, no source apply/Undo, and that a later Replace only requests a fresh query:

- `testPendingFindDeliveryCannotBlessChangedSourceAtSameRevision`
- `testPendingFindDeliveryUsesRawUnicodeSourceRatherThanCanonicalEquality` (`café` versus `cafe\u{301}`: Swift canonical equality is true while raw UTF-16 differs).

## Current validation

The [shared portable receipt](../lane-09/acceptance-review-fixes.md) records **149 executed Mac XCTest cases, all passed**, including **89 Authoring** (7 accepted-Find, 9 guarded-edit, 17 generation, 18 formatting, 16 frontmatter-panel, 6 projection, 3 actual scheduler, 13 single-replace). This compiles unchanged production Authoring source and uses the existing private editor doubles; it does not exercise UIKit input or native Undo. The two new Find cases actually fail when the delivery guard is removed from the task-owned harness copy and pass after byte restoration. [Named positive cases](https://github.com/w3d-su/plainsong/blob/e20162e5c2402800e84cf1f68ae4787535228c50/docs/ios/evidence/lane-09/review-20261013/portable-positive-cases.json), [negative cases](https://github.com/w3d-su/plainsong/blob/e20162e5c2402800e84cf1f68ae4787535228c50/docs/ios/evidence/lane-09/review-20261013/portable-negative-cases.json), [copy provenance](https://github.com/w3d-su/plainsong/blob/e20162e5c2402800e84cf1f68ae4787535228c50/docs/ios/evidence/lane-09/review-20261013/portable-copy-manifest.json).

Generic iOS Simulator `build-for-testing` succeeded with signing disabled, compiling **155 scoped App cases**: 89 Authoring, 60 Images, and 6 App contract consumers. **Current native execution: 0.** Runtime attempts were interrupted or failed concrete destination discovery; no later simulator PASS is inferred. The six contract consumers did not run in the portable harness.

Exact repository config and SwiftFormat **0.62.1** final lint: **0/38 owned Swift files require formatting**. Four pre-existing Authoring files were wrapped after the successful build/test snapshot. [Before/after hashes](https://github.com/w3d-su/plainsong/blob/e20162e5c2402800e84cf1f68ae4787535228c50/docs/ios/evidence/lane-09/review-20261013/format-equivalence.json) and an exact quoted-literal/non-whitespace-token comparison prove only formatting changed. This is an additive correction; the Oct9 receipt's formatting result is retained as its historical observation. `git diff --check` passed.

## Remaining gates

No EditorKitIOS/history, shared contract, app state, package or project source changed. Native production editor/command/provider integration, Chinese marked-text input, real Undo/Redo, external keyboard, VoiceOver, iPhone/iPad, M0 and performance remain OPEN. Root owns integration, publication and exact-head CI; this task made local commits only. Final input hashes and the nonsemantic post-proof deltas are in [source inventory](https://github.com/w3d-su/plainsong/blob/e20162e5c2402800e84cf1f68ae4787535228c50/docs/ios/evidence/lane-09/review-source-inputs-20261013.json).
