# Release Engineering Plan (R14)

> **Status: PLAN. No release pipeline exists yet; public alpha stays blocked (risk R14).**
> agent.md §15 locks the direction: "Sign to Run Locally" for dev; hardened runtime +
> notarization scripted later; direct distribution first, App Store optional. This document
> turns that into ordered work packages with gates. Owner decisions are marked **[owner]**.

Created 2026-07-02. Current state: no `LICENSE` file, no Developer ID signing, no
notarization, no packaging, no release CI. The app builds and runs locally with the sandbox
and `com.apple.security.network.client` entitlements.

## P0 — Decisions before any pipeline work [owner]

| # | Decision | Notes |
|---|---|---|
| P0.1 | License | Repo has **no LICENSE file today** (CI's old ignore list referenced one preemptively). Closed-source freeware, source-available, or OSS all change distribution/marketing wording. Blocking for any public artifact. |
| P0.2 | Distribution channel for alpha | §15 says direct-first. Confirm: direct download (DMG from GitHub Releases or site) now; App Store evaluated post-1.0. |
| P0.3 | Update mechanism | Options: none for alpha (manual downloads), Sparkle 2 (adds a dependency → Decision Log + sandbox/XPC review), or App Store later. Recommendation: **none for alpha**, revisit at beta. |
| P0.4 | Crash/feedback channel | Default: no telemetry (aligns with offline-first posture); feedback via GitHub Issues. Any crash reporter is a new dependency → Decision Log. |
| P0.5 | Version scheme | Recommendation: SemVer-ish marketing version (`0.x` alphas) + monotonically increasing build number stamped by the release script. |

## P1 — Identity & signing

- Enroll/confirm Apple Developer Program team; create **Developer ID Application**
  certificate (direct distribution does not use App Store certs).
- Audit entitlements for the hardened runtime: App Sandbox stays ON, keep
  `com.apple.security.network.client` (Decision Log 2026-06-12), user-selected read/write +
  security-scoped bookmarks. No JIT/unsigned-memory exceptions should be needed; WKWebView
  works under hardened runtime without them.
- `project.yml`: add a Release signing configuration (identity via build setting or
  environment, never a committed secret); keep "Sign to Run Locally" for Debug.
- Gate: `codesign --verify --deep --strict` and `spctl --assess` pass on a Release build.

## P2 — Notarization

- Script `xcrun notarytool submit … --wait` + `xcrun stapler staple` using an App Store
  Connect API key (stored outside the repo; CI secret if/when automated).
- Gate: notarized, stapled app launches with no Gatekeeper prompt on a clean macOS 14 VM
  (first-launch quarantine test), sandbox intact.

## P3 — Packaging

- DMG via a scripted `hdiutil` flow (`Scripts/make-dmg.sh`) — no new dependency needed;
  `create-dmg` would require a Decision Log entry and isn't justified for a plain
  app-plus-Applications-symlink layout.
- `make release`: clean Release build → sign → notarize → staple → DMG → checksum
  (`shasum -a 256`), stamping P0.5 version/build numbers.
- Gate: `make release` is reproducible on a dev machine from a clean checkout with only
  documented secrets.

## P4 — Release CI (optional for alpha)

- Tag-triggered (`v*`) GitHub Actions workflow running `make release` and attaching the DMG
  + checksum to a GitHub Release.
- Mind the macOS-minutes budget (see the 2026-07-02 CI Decision Log entry — quota exhaustion
  took CI down for a week): release builds are rare, but keep them manual-dispatch or
  tag-only, never per-push.
- Secrets: Developer ID cert (base64 keychain import) + notary API key as repo secrets.
- Gate: one tagged release produced end-to-end by CI, artifact passes the P2 clean-VM test.

## P5 — Alpha readiness checklist

- [ ] P0 decisions recorded in the Decision Log.
- [ ] LICENSE committed; README states license + support channel.
- [ ] Signed, notarized, stapled DMG from `make release` installs and launches on a clean
  macOS 14 VM (Gatekeeper-quiet), opens a workspace, edits/saves/previews offline.
- [ ] WYSIWYG remains Experimental/off by default in the shipped build (checklist §D.4).
- [ ] `docs/perf-log.md` budgets re-verified on the Release configuration (§12 gates were
  measured on Debug; Release should only improve, but record one Release pass).
- [ ] Known-limitations section in README (e.g., M2 single-file sibling-asset scope note).

R14 closes when P5 is fully checked; until then public distribution stays blocked.
