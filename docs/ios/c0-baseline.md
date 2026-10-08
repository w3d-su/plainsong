# C0 baseline and manifest transfer receipt

Published 2026-10-08, after [draft PR #157](https://github.com/w3d-su/plainsong/pull/157) was created. PR base: `main`; spec ancestor #153 is included. Frozen version: IOS-C0-v1.

```sh
IOS_BASE_REF=refs/tags/ios-c0-v1
IOS_BASE_SHA=642cb212703220409874a2741c5adbfb8c80fe8a
```

Both values were matched using live `git ls-remote`. The tag remains at the code freeze; the integration branch advances only with this documentation receipt. It is not a new implementation base.

```sh
git fetch origin refs/tags/ios-c0-v1:refs/tags/ios-c0-v1
test "$(git rev-parse refs/tags/ios-c0-v1)" = 642cb212703220409874a2741c5adbfb8c80fe8a
# Use a fresh lane-specific destination/branch; never reset an occupied worktree.
git worktree add /private/tmp/plainsong-ios-<lane> -b phase3-ios-<lane> 642cb212703220409874a2741c5adbfb8c80fe8a
```

The `<lane>` strings are explanatory placeholders. If a branch/worktree already exists, inspect and preserve its work; use an additive adoption or a separately named implementation worktree. Never substitute newest main or force-reset a research/prototype branch.

Exclusive transfer is effective in this receipt commit; the exact commit is available from `git log -1 --format=%H -- docs/ios/c0-baseline.md` and the PR body. 02 gets SyntaxKit/EditorKit manifests, 03 WorkspaceCore/WorkspaceKit manifests, 04 EditorKitIOS manifest, 07 PreviewKit manifest. **12 exclusively gets project.yml / Makefile / Scripts/ios / ios.yml.** 13 retains WorkspaceKitIOS/MarkdownCore manifests and all frozen contracts, central docs/architecture checks and production composition.

C0 global bootstrap includes `ios-c0-build` / `ios-c0-test`; 12 implements the formal ios-build/test/archive/ipa entries and manual workflow. App target/scheme: PlainsongIOS. Hosted test target: PlainsongIOSTests. AppIOS and AppIOSTests sources are recursive; SwiftPM module source/test subdirectories are automatic. PreviewKitContracts is the pure C0 product; full PreviewKit UIKit provider is still 07's work.

Clean freeze-head build: `642cb212703220409874a2741c5adbfb8c80fe8a`, dirty=false, Xcode 27.0 / Simulator SDK 27.0 / deployment 26.0, both architectures, all test products, 64 bundled preview resource hashes match. Artifact locator: `/private/tmp/plainsong-ios-c0/642cb212703220409874a2741c5adbfb8c80fe8a-build.ZPVo8p`. Twelve selected cases are **compiled, not executed**; no runtime/devices installed. C0 overall smoke gate remains OPEN. M0 and complete production composition remain blocked; no IPA/provider success is claimed.

[Contract signatures and ownership](contracts.md#9-c0-唯一宣告索引與精確-seams), [integration ledger](integration-ledger.md), [local evidence](evidence/lane-13/c0-verification.md), [frozen digests](evidence/lane-13/frozen-contracts.json). Claude review pending; maintainer handles merge.
