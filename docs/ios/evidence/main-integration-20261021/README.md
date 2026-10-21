# iOS phase A main integration — 2026-10-21

This candidate joins main `15913f882b4994280f239fc90ee5f8d52d5f043b` with the
review aggregate `fdd2a071c04f61f5259d31cf17699534d77fce9e` and diagnostic
follow-up `a13c845e3536a147a6dfdbf6ce09c60bf1efda2c`.

## Scope

- Retain main's STTextView 2.4.1 and all Mac editor, preview, sandbox and CI fixes.
- Preserve shared SyntaxKit extraction and main's prepared-coverage parser path.
- Keep one preview asset context with the explicit iOS grant helper.
- Keep AppKit PDF capture and measurement macOS-only; pure geometry remains portable.
- Preserve the Decision Log archive and move all 11 incoming iOS decisions into files.
- Keep frozen IOS-C0-v1 contracts, unavailable C0 composition and disabled acceptance seam.

## Validation status

Native execution used clean merge candidate
`318be8ddf9189b09e7e030e7b29d5e9d017005d8`, Xcode 27.0 (27A5194q), and an
iOS 27.0 iPhone simulator. The subsequent fix changes the Mac sandbox linker and
documentation only; all 755 captured iOS input records remain equal. Verify that
boundary with `python3 Scripts/ios/ios-provenance.py verify-source
docs/ios/evidence/main-integration-20261021/native-source.json`.

| Check | Result | Receipt |
|---|---|---|
| Public `make ios-preview` | 155 Passed, 0 Failed, 0 Skipped; all original 94 names retained | `preview-gate.json` |
| Public `make ios-test` | 362 Passed, 0 Failed, 0 Skipped; all historical 300 names retained | `modules-gate.json` |
| Separate first real-bundle controller in a new app-host test execution | 1 Passed, 2.792 s; unchanged production-default bundle assertions and 8 s / 2 s limits | `first-controller-gate.json`, `verification.json` |
| iOS tooling | 44 Passed; the restricted-sandbox attempt is retained separately | `verification.json` |
| Pinned lint | SwiftFormat 0.62.1: no formatting changes; SwiftLint: 0 serious, 404 warnings | `verification.json` |
| Actual signed single-file-save sandbox probe after linker fix | PASS: sibling create refused, two durable saves, no leftover staging | `verification.json` |
| Frozen contracts / architecture | 13 unchanged C0 files; exact package/target checks retained | Native and CI receipts |

Each native run has a complete xcresult, original logs, resource/admission reports
and driver records retained with this task's local evidence. The committed source
manifest and complete named-case gates are inspectable without local build paths.
Native source verification and required-copy checks passed before and after the
public runs. The first-controller run also rechecked resources, app-host admission
and source; its two test helper files match reviewed #173 byte for byte.

The module run's six bundles reported passes before Xcode spent about 600 seconds
in its automatic simulator-diagnostics collection. A retained process sample
observes that wait; no agent stopped the process or reset services. The normal
runner eventually returned 0 and its complete result parsed as 362/362. This does
not establish why diagnostics started or diagnose an earlier failure.

The first combined CI [39537624932](https://github.com/w3d-su/plainsong/actions/runs/39537624932)
passed Preview, both hosted shards and the package test suites, then failed the
single-file-save sandbox probe linker with missing WorkspaceCore symbols. Its raw
failure log is retained. The manual object collector now includes WorkspaceCore;
the actual signed probe passed locally without changing save logic or assertions.
Final full CI is tracked by [PR #188](https://github.com/w3d-su/plainsong/pull/188),
not inferred from the first run or from local tests.

The iOS preview gate retains every original required case and its 8 s / 2 s
limits. Pure geometry cases added on main may increase the executed count;
the original required-name set and no-skip gate stay intact.

Run `shasum -a 256 -c SHA256SUMS` from this directory to verify the committed
manifests and results. The two inherited text records listed in
`retained-text-compression.json` were preserved through byte-equal gzip so raw
outputs were not edited for whitespace.

## Open product gates

M0 physical iPhone/iPad, iOS 26 runtime, Traditional Chinese IME/Undo,
Files/iCloud/offline/conflict/background persistence, owner re-sign/install,
production composition, composed-app acceptance, accessibility/performance and
release IPA remain open. No product provider is installed by this integration.

Maintainer/Claude review and merge remain separate. The agent does not self-merge.
