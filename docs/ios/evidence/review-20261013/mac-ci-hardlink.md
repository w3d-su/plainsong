# Mac CI hard-link spelling proof — 2026-10-13

> Historical raw evidence and replay files referenced below are preserved at `e20162e5`. See the [archive index and restoration instructions](../README.md); run historical local-path commands from that restored checkout.

Source commits: `ed151f99fd0a71006e058e0def7ff1519acdb023` and additive native-buffer assertions `f42607700063a53ceba07694931b52ec2e03879c`. Branch `codex/ios-mac-ci-kernel-proof`, based on exact integration head `46ef53e74cc433f328a0833ded82190f3176d1a5`, in `/Users/davis._.su/.codex/worktrees/ios-review-authoring/blogeditor`. The previous `codex/ios-authoring-review-fixes` branch remains at `5826cb2acd82ec43ca718539cc8d2e91549cc082`. Root owns integration/publication; no push, PR, owner-checkout mutation or global simulator operation was performed by this task.

## Confirmed failure and limit

[Original failed CI log](https://github.com/w3d-su/plainsong/blob/e20162e5c2402800e84cf1f68ae4787535228c50/docs/ios/evidence/review-20261013/mac-ci-hardlink-failed-ci-38359852530.log.gz), run `38359852530` on PR #164 head `46ef53e`: WorkspaceKit **360 cases, 1 unexpected failure**; ExportArtifactWriter **67 cases, 1 failure**. `testHardLinkInspectionUsesCurrentKernelSpelling` threw `destinationAlias` at line 160 while expecting successful inspection after opening `link.html`. Preflight, Hooks and PublicationTests were byte-identical to merged #141 (`1e91ee45`). This batch had not changed Export code. The observer ran before real `F_GETPATH`; source control flow implies the successful syscall's bytes failed exact comparison. The failed log does not contain the actual returned path. The specific historical kernel/cache cause remains **unattributed**; a passing local run does not explain it.

## Minimal correction and production invariant

The writer still performs **one real `fcntl(F_GETPATH)` per existing-leaf proof**, checks real opened identity/type, and retains the unchanged `kernelPath.elementsEqual(leafPath.utf8)` guard and `.destinationAlias` refusal. Two internal hooks default to nil in production: first an observer records the actual unmodified returned bytes; only afterwards an explicitly named `kernelPathOverrideForTesting` can control the comparison bytes in a test. With nil hooks the raw returned bytes go directly to the original guard. No spelling, grant, identity, permission or publication policy was relaxed.

- `testHardLinkInspectionUsesCurrentKernelSpelling` records selected/returned UTF-8, lookup open result/errno and real identity. It requires nonempty absolute returned bytes and asserts success or refusal against **that same syscall's raw bytes**, without predicting which hard-link spelling the kernel chooses after a lookup. The production defaults are asserted nil; there is no override in this case.
- `testHardLinkMatchingKernelSpellingInspectsExactIdentity` requires success for controlled matching comparison bytes and exact real identity/selected URL.
- `testHardLinkMismatchedKernelSpellingRefusesWithoutStaging` requires controlled mismatch to refuse inspection/publication, zero staging/publish calls, and unchanged identity/content of both names and directory entries. Both controlled cases still execute real metadata/open/`fcntl`, record raw bytes before override, and assert observer-before-override ordering. Their forced comparison outcomes are **controlled boundary proof**, separate from native kernel behavior.

[Telemetry](https://github.com/w3d-su/plainsong/blob/e20162e5c2402800e84cf1f68ae4787535228c50/docs/ios/evidence/review-20261013/mac-ci-hardlink-telemetry.json) retains complete selected and raw returned bytes separately from effective controlled paths. In the final local native samples, lookup of `link.html` was followed by returned `link.html`, and lookup of `export.html` by returned `export.html`, with the same device/inode. That is a local observation, not attribution of the prior CI failure. stdout can flush after XCTest stderr; the JSON groups ordered lookup/override markers and does not infer wall-clock timing from interleaved log lines.

## Executed proof

All tests ran under `/private/tmp/plainsong-xcodebuild-test.lock`, with 45-second bounded admission and a 600-second timeout per child; termination targets only the runner-owned process group. Scratch path `/private/tmp/plainsong-mac-ci-kernel-dd-20261013`. Environment: macOS 27.0 build 26A428, Apple Swift 6.4, arm64; package deployment remains macOS 14 and manifest Swift 5.10. No package/manifests or dependencies changed.

| Final-source run | Actual named cases | Exit/result |
|---|---:|---|
| Exact guard removed temporarily; mismatch case | 1 | exit 1; expected named FAIL, 7 assertion failures |
| All three source files restored by exact SHA-256 | — | before/restored/final hashes identical |
| ExportArtifactWriter focused | 69 | exit 0; 69 passed, 0 failed, 0 skipped |
| Full WorkspaceKit | 362 | exit 0; 362 passed, 0 failed, 0 skipped |

The negative test actually accepted inspection, published a replacement, created staging, and changed the chosen link's identity/content after the guard was removed; its assertions detected those effects. The controlled fixture and staging residue are test-owned and torn down. That negative child's exit 1 is intentional evidence; the wrapper's exit 0 only follows successful restoration and positive proofs. The temporary mutation produced an expected unused-`kernelPath` warning; it is retained in the negative log. The Swift Testing footer reported 0 tests and is not counted as XCTest execution.

Initial source completed the same negative/69/362 sequence at `2026-10-13T07:35:25.148280Z`. After Root requested two native returned-buffer validity assertions, a bounded final sequence was already running before Root reduced the required rerun scope to three named cases. It completed at `2026-10-13T07:37:33.044869Z`; all three named hard-link cases passed in both final positive runs. No further tests were scheduled. Initial and final logs/hashes are preserved separately rather than overwritten.

Commands use `swift test --package-path <worktree>/Packages/WorkspaceKit --scratch-path /private/tmp/plainsong-mac-ci-kernel-dd-20261013`, with filters `ExportArtifactWriterTests.testHardLinkMismatchedKernelSpellingRefusesWithoutStaging` for the negative and `ExportArtifactWriterTests` for focused execution. The [proof JSON](https://github.com/w3d-su/plainsong/blob/e20162e5c2402800e84cf1f68ae4787535228c50/docs/ios/evidence/review-20261013/mac-ci-hardlink-proof.json) contains exact commands, named outcomes, before/restored/final source hashes, baseline hashes, compressed-log hashes and the bounded runner source for reproduction.

Pinned SwiftFormat **0.62.1**, exact repository `.swiftformat`: **0/3 files require formatting**. `git diff --check` passed. Source peer review found no actionable blocker; explicit zero-publication and native buffer-validity assertions were included additively.

## Evidence scope and open gates

This closes the local spelling-comparison proof without claiming a kernel/cache repair. Exact final-head Mac CI, the full application aggregate and Root integration checks are separate pending evidence. Historical failed CI remains a failed run. iOS runtime, real device/IME/Undo/provider/M0/performance/signing gates retain their prior OPEN state. Only the three allowlisted source files and this receipt with its JSON/compressed logs changed.
