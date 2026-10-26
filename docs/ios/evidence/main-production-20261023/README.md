# Main-based iOS production integration — 2026-10-23

[#210](https://github.com/w3d-su/plainsong/pull/210) targets `main`, based on
`cdb528d4a565cd15e31ddc1b6312b5a45b27236a`.
Branch: `codex/ios-main-production-20261023`.
Tested implementation: clean `1c1685adb7a594f3ecaf81a16d61f5d41e032363`.
The subsequent receipt commit changes documentation only; native execution is
not relabelled to that publication head.

Only #209's single squash patch was cherry-picked as `af1d895`; then the
acceptance manifest's bundle.js digest was adapted to main's retained #195
resource. The original transplant has identical patch-id and 63/63 post-blobs;
main's Mac/Preview trees, dependency pins, protocol and frozen13 remain unchanged.
The retained checksum control was35 PASS/1 FAIL before,36 PASS/0 FAIL after.
[Static receipt](integration-static.json), [authority review](authority-review.md).

| Source-bound check | Actual result |
|---|---|
| Full modules / real production workflows | 448/448;81 required names;zero failure/skip |
| Complete IOSPreview | 191/191;104 required names;zero failure/skip |
| Consecutive unchanged-source complete repeat | 191/191;104 required names;zero failure/skip |
| Enabled-plan actual UI launch, iPhone / iPad iOS27 | 1/1 each;zero failure/skip |
| Acceptance components / tooling | 29/29 and44/44 |
| Local Mac PreviewKit | 195 total;192 passed,3 existing opt-in skips,0 failures |
| Architecture / Mac build | 6/6 andBUILD SUCCEEDED |
| Pinned lint | SwiftFormat0.62.1 PASS;SwiftLint410 warnings,0 serious |
| Implementation-head Mac/JS/package/hosted CI | [39953280833](https://github.com/w3d-su/plainsong/actions/runs/39953280833), all six checksPASS |
| New unsigned Release device IPA | Independently auditedPASS;3,096,043bytes |

All five simulator runs, components and Release use source fingerprint
`7199986ef78e15c5596dd30457998e2fb9546d38d01254b7eedced68437fb8c1`.
The full modules run completed all448 cases across6 test images before only its
owned post-case simctl diagnose child was terminated under counts, ancestry,
canonical path and source guards. Runner exit0; raw diagnostics and xcresult
remain. Both complete Preview runs and both UI launches completed uninterrupted.
The initial `af1d895`448/448 run remains a separate pre-manifest-adaptation receipt.

IPA SHA-256:
`0584f658209be0e669556745067002d01e6a0df9787feca1d973a8c7f320ed87`.
Actual ZIP/Mach-O/Info/UTI/nested signing/resource audit:arm64 IOS,minimum26,
iPhone+iPad,in-place Markdown/MDX,no signing material,exact committed preview.
No signing/install result is inferred. The kit's Chinese installation/checklist,
owner template, IPA andSHA256SUMS are delivered in this Codex chat.

[Candidate receipt](candidate-receipt.json) binds every actual head, required
name/case count, complete raw xcresult locator and release/audit receipt.
[Local Mac receipt](mac-receipt.json) retains full names including the3 skips.
Raw root:`/private/tmp/plainsong-ios-main-production-20261023`.
Complete xcresults and DD/Mach-O hosts remain there. The delivered kit copies
enabled xctestruns/schemes, case inventories and UI host/target byte hashes.

The launch case only proves Files/Open. Simulator real-provider workflows are
separate from owner Files/iCloud→native edit→preview→save→reopen,Chinese/Undo,
background/relaunch and installation of this new artifact. Old M0's named
OWNER_REPORTED_PASS remains accepted at its original pre-composition scope.
Physical iPad/minimumOS26,VoiceOver,hardware keyboard,performance andv1 remainOPEN.
Recovery-list/readback/restore andconflict Save a Copy follow as separate PRs;
recents/reselection UI was also found unconnected and is tracked independently.

Reproduce using the fixed public runners (each acquires the canonical lock):
`make ios-test`, `make ios-preview` twice, `make ios-acceptance` for each actual
installed destination, `make ios-acceptance-components`, `make ios-ipa`, and
`make test-ios-tooling`. Use per-run IOS_OUTPUT_ROOT and explicit actual
IOS_DESTINATION; do not wrap a public runner with its own lock.
