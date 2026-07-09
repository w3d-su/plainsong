# Release Engineering Plan (R14)

> **Status: P5 COMPLETE (2026-07-05); R14 CLOSED. Unsigned alpha cleared for public distribution. P1/P2 signing remain DEFERRED until Apple Developer Program membership.**
> agent.md §15 locks the direction: "Sign to Run Locally" for dev; hardened runtime +
> notarization scripted later; direct distribution first, App Store optional. This document
> turns that into ordered work packages with gates. Owner decisions are marked **[owner]**.

Created 2026-07-02. Current state (2026-07-05): MIT `LICENSE` committed; packaging
(`make release`, P3) and unsigned release CI (`release.yml`, P4) landed; v0.1.0-alpha.1 is
published. Developer ID signing and notarization remain deferred with P1/P2. The app builds
and runs locally with the sandbox and `com.apple.security.network.client` entitlements.

## P0 — Decisions before any pipeline work [owner]

**All P0 decisions were made by the owner on 2026-07-02** (Decision Log entry of the same
date). P1 pipeline work is unblocked.

| # | Decision | Decided 2026-07-02 |
|---|---|---|
| P0.1 | License | **MIT**, copyright `w3d-su`. `LICENSE` file committed; README License section updated. |
| P0.2 | Distribution channel for alpha | **Direct download** (DMG via GitHub Releases or site). App Store is deliberately left as a future decision — not scheduled, to be re-evaluated later; sandbox-on keeps it possible. |
| P0.3 | Update mechanism | **None for alpha** (manual downloads). Sparkle or any updater needs its own Decision Log entry; revisit at beta. |
| P0.4 | Crash/feedback channel | **No telemetry**; feedback via GitHub Issues. Any crash reporter is a new dependency → Decision Log. |
| P0.5 | Version scheme | **`0.x` marketing version + monotonically increasing build number** stamped by the release script. |

## P1 — Identity & signing — DEFERRED (owner decision 2026-07-02)

The owner is not purchasing Apple Developer Program membership for the alpha. Alpha
builds ship **unsigned** via `PLAINSONG_UNSIGNED=1 make release` (ad-hoc signature,
"-unsigned" DMG suffix), with the Gatekeeper bypass documented in README "Installing
(alpha)"; build-from-source remains the zero-friction path for the MIT-licensed repo.
P1/P2 resume unchanged when membership is purchased (target: before any beta / wider
distribution). The steps below are retained for that moment.

- Enroll/confirm Apple Developer Program team; create **Developer ID Application**
  certificate (direct distribution does not use App Store certs).
- Audit entitlements for the hardened runtime: App Sandbox stays ON, keep
  `com.apple.security.network.client` (Decision Log 2026-06-12), user-selected read/write +
  security-scoped bookmarks. No JIT/unsigned-memory exceptions should be needed; WKWebView
  works under hardened runtime without them.
- `project.yml`: add a Release signing configuration (identity via build setting or
  environment, never a committed secret); keep "Sign to Run Locally" for Debug.
- Gate: `codesign --verify --deep --strict` and `spctl --assess` pass on a Release build.

## P2 — Notarization — DEFERRED (with P1)

- Script `xcrun notarytool submit … --wait` + `xcrun stapler staple` using an App Store
  Connect API key (stored outside the repo; CI secret if/when automated).
- Gate: notarized, stapled app launches with no Gatekeeper prompt on a clean macOS 14 VM
  (first-launch quarantine test), sandbox intact.

## P3 — Packaging

Scaffolding landed 2026-07-02: `Scripts/release.sh` (build → sign → notarize → staple →
DMG → checksum, env-driven credentials, `PLAINSONG_SKIP_NOTARIZE=1` for pre-P2 smoke runs)
and `Scripts/make-dmg.sh`, wired to `make release`.

First real run 2026-07-05 (owner's Mac): `PLAINSONG_UNSIGNED=1 make release` produced
`Plainsong-0.1.0-56-unsigned.dmg` end-to-end (build number 56 from git commit count,
SHA-256 `7ce63ecd…0153b3c`, bypass instructions printed). Known cosmetic note: newer
macOS warns that `hdiutil create` is deprecated in favor of `diskutil image create`;
hdiutil still works and stays until compatibility needs force a change.

- DMG via a scripted `hdiutil` flow (`Scripts/make-dmg.sh`) — no new dependency needed;
  `create-dmg` would require a Decision Log entry and isn't justified for a plain
  app-plus-Applications-symlink layout.
- `make release`: clean Release build → sign → notarize → staple → DMG → checksum
  (`shasum -a 256`), stamping P0.5 version/build numbers.
- [x] Gate: `make release` is reproducible on a dev machine from a clean checkout with only
  documented env (unsigned path verified 2026-07-05, build 56). The signed-path run
  re-verifies this gate when P1/P2 resume.

## P4 — Release CI (unsigned path implemented 2026-07-05)

`.github/workflows/release.yml` runs on `v*` tags and `workflow_dispatch` only (never
per-push, per the 2026-07-02 CI-cost decision): macos-15 runner, full-history checkout
(build number = commit count), `PLAINSONG_UNSIGNED=1 make release`. Tag runs upload the
DMG + SHA-256 to the tag's GitHub Release — created as a **draft prerelease** when absent,
so the owner still authors the notes and presses publish. Dispatch runs attach the DMG as
a workflow artifact for pipeline verification without touching Releases. No secrets are
required on the unsigned path, and public-repo macOS minutes are free.

- Secrets (Developer ID cert keychain import + notary API key) become repo secrets only
  when the signed path resumes with P1/P2.
- [x] Gate: one tagged release produced end-to-end by CI. Verified 2026-07-09: pushing
  `v0.1.0-alpha.2` ran Release workflow run #1 to success in ~3 minutes and created the
  draft prerelease with the DMG + `.sha256` (filename-only format) and auto-generated
  notes; the owner reviews and publishes. The artifact family already passed the P5
  clean-machine test with alpha.1; spot-checking each published DMG on install remains
  good practice.

## P5 — Alpha readiness checklist

- [x] P0 decisions recorded in the Decision Log (2026-07-02).
- [x] LICENSE committed (MIT); README states license + GitHub Issues feedback channel.
- [x] Alpha DMG installs and launches on a second Mac via the documented Gatekeeper
  bypass, opens a folder workspace, edits/saves, and renders the preview offline
  (owner-verified 2026-07-05 with `Plainsong-0.1.0-56-unsigned.dmg`). (Original
  signed+notarized wording resumes with P1/P2.)
- [x] WYSIWYG remains Experimental/off by default in the shipped build (owner-verified in Settings on the second Mac, 2026-07-05; checklist §D.4 unchanged).
- [x] `docs/perf-log.md` budgets re-verified on the Release configuration (2026-07-05,
  owner's Mac, Xcode beta 27A5194q): all §12 budgets pass with margin — typing 0.525 ms max,
  highlight 8.5/10.1 ms, preview medians 46.7/14.7 ms, file open 32.0 ms, 149.3 MB host RSS.
  See "Release Configuration Verification (P5)" in `docs/perf-log.md`.
- [x] Known-limitations section in README (single-file sibling assets, MDX placeholders, image policy, WYSIWYG scope, no auto-update).

**P5 is fully checked as of 2026-07-05 and R14 is closed: the unsigned alpha is cleared
for public distribution** (tag + GitHub Release with the DMG and SHA-256). P1/P2 signing
and the P4 release-CI option remain available when membership is purchased.
