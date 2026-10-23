# Main-based iOS production integration — 2026-10-23

PR: [#210](https://github.com/w3d-su/plainsong/pull/210), base `main` at
`cdb528d4a565cd15e31ddc1b6312b5a45b27236a`.
Branch: `codex/ios-main-production-20261023`.

The single #209 squash patch was cherry-picked without conflicts as `af1d895`.
It preserves main's newer Mac/Preview changes. The only source adaptation is the
acceptance manifest's bundle.js digest to match main's #195 resource.
The initial unadapted transplant executed modules/workflows 448/448 with zero
failures/skips. Its evidence is retained separately under
`/private/tmp/plainsong-ios-main-production-20261023/modules`.

Current combined-head validation is pending. Complete modules/workflows,
full IOSPreview plus an unchanged-source complete repeat, actual launch smoke,
Mac regression/exact-head CI and a new unsigned Release IPA will each retain
their head, source fingerprint, required names, actual counts and raw results.
Raw evidence root: `/private/tmp/plainsong-ios-main-production-20261023`.
No historical #209 native result or IPA is current-main acceptance.

The one-case UI smoke checks Files/Open shell launch only. Actual Files/iCloud
open → native edit → preview → save → reopen, Chinese IME/Undo and background
recovery require acceptance of the new composed artifact. Earlier M0 reports
remain valid at their original pre-composition scope. Physical iPad/minimum OS26,
VoiceOver/hardware keyboard/performance and full v1 remain OPEN.
