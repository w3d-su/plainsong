# PR 164 follow-up review — 2026-10-26

Both findings in pending review `5650939520` apply to
`c9a25dbd392d16d7e43fb91f209a6815b0e4e64b`.

- A resolved bookmark remains available after cancellation, offline metadata,
  coordination failure or another transient provider refusal. Permanent access/path
  refusal still requires reselection. A timed-out or cancelled metadata operation
  retains its started scope until the port drains; it cannot mint a late replacement.
- Root listing failures publish unavailable only for the latest request on the current,
  live grant. Superseded success, coordination failure and offline failure cannot hide
  a newer successful tree. The offline publication inside `directorySnapshot` carries
  the same ticket admission; fixing only the root catch would leave that race open.
- The confirmed PR 221 close/relay repair also applies here. A read drained during close
  holds its reload proposal instead of synchronously dirtying the attached editor.
  Successful close discards it; failed provider close delivers it after closing ends so
  acknowledgement can rebase the still-installed document. Later main-only deferred
  observation barriers are outside this historical source and are preserved in the port.

Source commits are `0173ab5` (access and root refresh) and
`ee03216e42113860a05026965e414845cb8b39a4` (close delivery). The latter is the exact source
tested below. This receipt commit changes documentation only.

The complete WorkspaceKitIOS simulator suite executed **131 passed, 0 failed, 0 skipped**
on iPhone 17 Pro / iOS 27.0 (`59CB04BD-26CC-4841-8D06-E75A2EDEBC66`), SDK 27.0, Xcode
`27A5194q`. It includes all previous 119 cases, ten bookmark/root regressions and two
attached-editor close regressions. `xcodebuild` exited 0 and the 522 package source/pin
records captured before and after the run were identical. SwiftFormat 0.62.1 and
SwiftLint passed on changed files; existing nonblocking length/complexity warnings remain.

The negative run restored the previous unconditional bookmark invalidation,
generation-only root error catch and unfenced offline publication while retaining the
new test entrypoints. All ten new access/root cases executed: **9 failed, 1 passed**,
exit 65. The one passing case proves a genuine latest listing failure still reports
unavailable. The other nine detect the invalidation and stale-publication policies.
Both mutated source files were restored byte-for-byte before the full passing run.

Both runs used `/private/tmp/plainsong-xcodebuild-test.lock`, disabled parallel testing,
retained normal per-test deadlines and requested `-collect-test-diagnostics never`.
They completed without stopping a process or running a UI-test target. Commands,
complete logs, source manifests, named results, summaries and mutation fingerprints
are preserved here as deterministic gzip files with SHA-256 values in `checksums.json`.
Complete xcresults remain at
`/private/tmp/plainsong-review164-round2-evidence/{final,negative-prior-policy}.xcresult`.

This is local simulator package evidence. Exact-head CI, production composition,
physical-device Files/iCloud/IME/background behavior, signing/install, performance,
accessibility and maintainer/Claude acceptance remain separate gates. The previous
119-case receipt in `../review164-20261026.md` remains historical evidence for its source.
