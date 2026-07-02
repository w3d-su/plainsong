# Release Engineering Plan (R14)

> **Status: P0 DECIDED (2026-07-02); pipeline work P1-P5 not started. Public alpha stays blocked (risk R14).**
> agent.md §15 locks the direction: "Sign to Run Locally" for dev; hardened runtime +
> notarization scripted later; direct distribution first, App Store optional. This document
> turns that into ordered work packages with gates. Owner decisions are marked **[owner]**.

Created 2026-07-02. Current state: MIT `LICENSE` committed; no Developer ID signing, no
notarization, no packaging, no release CI. The app builds and runs locally with the sandbox
and `com.apple.security.network.client` entitlements.

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

- [x] P0 decisions recorded in the Decision Log (2026-07-02).
- [x] LICENSE committed (MIT); README states license + GitHub Issues feedback channel.
- [ ] Signed, notarized, stapled DMG from `make release` installs and launches on a clean
  macOS 14 VM (Gatekeeper-quiet), opens a workspace, edits/saves/previews offline.
- [ ] WYSIWYG remains Experimental/off by default in the shipped build (checklist §D.4).
- [ ] `docs/perf-log.md` budgets re-verified on the Release configuration (§12 gates were
  measured on Debug; Release should only improve, but record one Release pass).
- [ ] Known-limitations section in README (e.g., M2 single-file sibling-asset scope note).

R14 closes when P5 is fully checked; until then public distribution stays blocked.
