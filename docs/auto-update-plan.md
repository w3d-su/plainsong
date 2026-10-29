# Auto-Update Plan (macOS)

> **Status: U1 adopted U-D1 and U-D3, 2026-10-29.** Answers V5 in `docs/release-1.0-scope.md`.
> U-D2 and U-D4–U-D7 stay owner 待決定. Adding Sparkle is a new Swift dependency, so the
> implementing PR carries a `docs/decisions/` entry (agent.md §2, §17.7). Sparkle facts
> below come from sparkle-project.org documentation (sandboxing, publishing, programmatic
> setup, customization), fetched 2026-10-29 and re-checked against Sparkle 2.10.0.
>
> U1 keeps `PLAINSONG_UPDATES_ENABLED=NO`. That build does not create or start an updater,
> makes no update network request, and hides Check for Updates… plus the Settings toggles.
> U-D3 (second-launch prompt, automatic checks after permission, automatic download off)
> applies only when the setting is YES. `SUFeedURL` and `SUPublicEDKey` stay empty until U2.
> U1 tests of the YES path use a fake client. Real Sparkle rejects the empty key and
> does not run a check until U2. The README "no auto-update" limitation stays until U3.

## 1. Baseline

- Distribution is a DMG attached to a GitHub prerelease by `.github/workflows/release.yml`
  (tag-triggered, no secrets). The README lists "no auto-update" as a known limitation.
- The app is sandboxed with `com.apple.security.network.client`
  (`App/Plainsong.entitlements`). It is ad-hoc signed; Developer ID signing and
  notarization (release plan P1/P2) wait for Apple Developer Program membership.
- `CFBundleVersion` is the commit count (`git rev-list --count HEAD`), so it increases
  with every release. `MARKETING_VERSION` stays `0.1.0` until V6. Sparkle compares
  `CFBundleVersion`, so the existing numbering works unchanged.
- Users on alpha.1–alpha.5 have no updater. They must install the first build that has
  one by hand; every build after that updates itself.

## 2. Owner decisions

| ID | Question | Proposed answer | U1 |
|---|---|---|---|
| U-D1 | Mechanism | **Sparkle 2** (alternatives in §7) | 已採用 |
| U-D2 | Ship before or after Developer ID signing? | **After P1/P2.** Build and test it now on a branch; enable it in the first signed build. §6 explains the unsigned risks | owner 待決定 |
| U-D3 | Default behavior | Ask on second launch (Sparkle's default); "Automatically check" on, "Automatically download and install" off until 1.0 | 已採用 |
| U-D4 | Feed host | `appcast.xml` on GitHub Pages (`gh-pages` branch), written by the release workflow | owner 待決定 |
| U-D5 | Channels | One stable feed plus a `beta` channel (`sparkle:channel`) that users opt into in Settings | owner 待決定 |
| U-D6 | Signing secret in CI | Store the EdDSA private key as a GitHub Actions secret, used only by the tag job. This reverses the 2026-07-02 "no secrets" rule and needs its own decision entry | owner 待決定 |
| U-D7 | Feed signing | Turn on `SURequireSignedFeed` (and its prerequisite `SUVerifyUpdateBeforeExtraction`) from the first release | owner 待決定 |


## 3. Design

### 3.1 App integration (App target only)

- Swift package `sparkle-project/Sparkle`, pinned by git revision
  `eef1a539a373c1f1a320624b1130fc5de7b2e100` (tag 2.10.0, at least two weeks old) in
  `project.yml` and linked only by the App target. MarkdownCore, EditorKit, PreviewKit
  and WorkspaceKit never import it (agent.md §17.3).
- One `SPUStandardUpdaterController`, created only when `PLAINSONG_UPDATES_ENABLED`
  is YES. U1 tests of that path use a fake client and do not start Sparkle. Real
  Sparkle rejects the empty `SUPublicEDKey` and does not check a feed until U2 fills
  the key and `SUFeedURL`. A **Plainsong › Check for Updates…** item is placed after
  About through `CommandGroup(after: .appInfo)`. It is enabled from
  `SPUUpdater.canCheckForUpdates`, as in Sparkle's SwiftUI sample.
- Settings › General gets "Automatically check for updates", "Automatically download and
  install updates" and "Receive beta updates". These bind to `SPUUpdater` properties
  (`automaticallyChecksForUpdates`, `automaticallyDownloadsUpdates`) and to the allowed
  channel set (updater delegate `allowedChannels(for:)`).
- Privacy: system profiling stays off (`SUEnableSystemProfiling` unset). The only network
  call is the HTTPS feed and archive download. Preview CSP and the Allow Remote Images
  policy are untouched.

### 3.2 Sandboxing

Sparkle supports sandboxed apps through its XPC services:

- `Info.plist`: `SUEnableInstallerLauncherService = YES`, `SUFeedURL`, `SUPublicEDKey`.
  The Downloader service (`SUEnableDownloaderService`) is not needed, because the app
  already holds `network.client`.
- Entitlements: `com.apple.security.temporary-exception.mach-lookup.global-name` with
  `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`.
- `Scripts/release.sh` re-signs Sparkle's `Installer.xpc`, `Downloader.xpc`,
  `Autoupdate`, `Updater.app` and the framework, innermost first. Signing never uses
  `--deep`. It re-signs before the app bundle so the outer signature is valid, then
  checks each nested item with `codesign --verify --strict` and the finished app with
  `codesign --verify --deep --strict` (verification only). A shipped plist whose
  `PLAINSONG_UPDATES_ENABLED` is not `NO` must have a 32-byte EdDSA key, the expected
  HTTPS feed (`https://w3d-su.github.io/plainsong/appcast.xml`), `SURequireSignedFeed`,
  and `SUVerifyUpdateBeforeExtraction`. The key check matches Sparkle's decoder
  (no padding repair, no interior whitespace). The feed check strips quotes only.
  CI runs the same guard on the Debug Info.plist after the ui-performance build. The installer-launcher key and the mach-lookup
  exceptions are present even when the flag is NO. They do not start the updater, and
  the temporary exceptions need a separate pass before a Mac App Store submission.

### 3.3 Quit and relaunch safety

Sparkle installs by terminating the app and relaunching the new one. Termination must go
through the normal `applicationShouldTerminate` path, so the app-global autosave flush
(agent.md §4 step 6), recovery stores and window-state quit rules
(`docs/window-state-gates.md` §6.3) all run. An update must never bypass a refusal to
quit, such as a save that cannot complete.

### 3.4 Release pipeline

1. `make release` builds and signs the DMG as today, with the Sparkle re-sign step.
2. A new `Scripts/make-appcast.sh` runs Sparkle's `generate_appcast` over a folder that
   holds the new DMG plus the previous DMGs it should build deltas from. It signs the
   archive and the feed with the EdDSA key from the secret. Release notes come from the
   GitHub release body, rendered to HTML.
3. The tag job keeps creating the **draft** GitHub Release. Publishing the feed is a
   second, manually dispatched job (`publish-appcast`) that the owner runs after
   publishing the release. Users therefore never receive a build the owner has not
   released. The job commits `appcast.xml` (and any delta files) to `gh-pages`.
4. Each feed item sets `sparkle:minimumSystemVersion` to `14.0.0` (agent.md §1).
   Prereleases carry `<sparkle:channel>beta</sparkle:channel>`.

### 3.5 Keys

- Generate the EdDSA pair once with Sparkle's `generate_keys` on the owner's Mac. Keep
  the private key in the login Keychain plus an offline backup, and copy it into the
  Actions secret (U-D6). The public key goes into `Info.plist`.
- Sparkle documents that rotating EdDSA keys needs a Developer ID-signed disk image, and
  that changing the Apple certificate and EdDSA key in the same release is unsupported.
  **Never change both at once.** Losing the private key strands every installed copy.

## 4. Work packages

| PR | Scope | Owner needed? |
|---|---|---|
| U1 | Decision entry; Sparkle package; updater controller; menu item; Settings toggles; Info.plist keys and entitlements; release-script re-signing; unit and hosted tests (§5) | No. `SUFeedURL` and `SUPublicEDKey` are empty strings until U2. YES is covered with a fake client, not a live Sparkle check |
| U2 | `make-appcast.sh`; `publish-appcast` workflow; `gh-pages` feed; README update | **Yes**: generate the keys and add the secret |
| U3 | End-to-end update gate (§5 U-G4–U-G7) against a local test feed, then against the real feed with a signed build | **Yes**: signed builds need P1/P2; the owner runs the clean-machine pass |

U1 can start now. U2 and U3 wait for the keys and, under U-D2, for Developer ID signing.

## 5. Gates

U1 closes U-G1 and U-G2. U-G3's unsigned path passed on 2026-10-29:
`PLAINSONG_UNSIGNED=1 make release` ran `codesign --verify --strict` on Installer.xpc,
Downloader.xpc, Autoupdate, Updater.app, Sparkle.framework, and the app, then
`build/release` was deleted. The Developer ID path is the same signer plus
`-o runtime --timestamp` and stays open until a signed release, because this machine has
no Developer ID identity. U-G4–U-G9 stay open for U2 and U3.

- [x] **U-G1** Layering: `git grep -n -w Sparkle -- Packages` has no hit; only the App
  target links Sparkle. `Scripts/check-sparkle-layering.sh` runs from `make test-packages`.
- [x] **U-G2** Info.plist and entitlements contain exactly the keys in §3.2. A hosted test
  reads them from the built bundle. `PLAINSONG_UPDATES_ENABLED=NO` does not start an updater.
  U1 leaves `SUFeedURL` and `SUPublicEDKey` empty.
- [ ] **U-G3** `codesign --verify --strict` passes for every nested Sparkle item and for
  the app in both the unsigned and Developer ID paths of `Scripts/release.sh`.
  The finished app is also `codesign --verify --deep --strict` (verification only).
  A non-`NO` shipped plist must pass the key, feed, and signed-feed guard.
  The key check matches Sparkle's decoder, and the feed check strips quotes only.
  Unsigned path: passed 2026-10-29, including the review-fix pass
  (`codesign --verify --strict` on each nested item, `--deep --strict` on the app,
  and the shipped-plist guard). The release directory was deleted afterward.
  Developer ID path: implemented, not executed.
- [ ] **U-G4** Build N updates to N+1 from a local HTTPS test feed with the app sandboxed.
  The new `CFBundleVersion` runs afterwards, and the security-scoped bookmarks,
  recents, preferences and recovery store survive the update.
- [ ] **U-G5** With a dirty document open, Install and Relaunch saves it first or is
  refused. Nothing is lost, and the warm sessions' recovery copies are intact.
- [ ] **U-G6** A tampered archive, a tampered feed, and an archive signed with another
  EdDSA key are all rejected.
- [ ] **U-G7** A build whose `minimumSystemVersion` is higher than the running macOS is
  not offered; a `beta` item is offered only when the beta setting is on.
- [ ] **U-G8** Typing latency and app host RSS (agent.md §12) are unchanged with the
  updater running. Record the result under `docs/perf/`.
- [ ] **U-G9** Clean-machine pass: the owner installs a signed build N on a second Mac,
  publishes N+1, and the update installs with no Gatekeeper prompt.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Unsigned (ad-hoc) builds: the sandboxed download is quarantined, and the updated app may hit Gatekeeper's "Open Anyway" again after every update | U-D2 ships only signed builds. If the owner wants it earlier, U-G4 on an unsigned build must prove the result first |
| Ad-hoc → Developer ID transition | Keep the EdDSA key fixed through the transition (§3.5). Test it explicitly in U3 |
| Private key loss or leak | Offline backup; the key is only in the tag-job secret; `SURequireSignedFeed` |
| A broken release reaches every user | Draft-first publishing (§3.4 step 3). Beta channel first. A fix ships as N+2; Sparkle never downgrades |
| An update interrupts unsaved work | §3.3 and U-G5 |

## 7. Alternatives considered

- **No dependency: check the GitHub Releases API and show "a new version is available"
  with a download link.** No install, no XPC services, no entitlement exceptions, and it
  works for unsigned builds today. It does not meet "auto-update", so it is only a
  fallback if Sparkle is rejected or U-D2 is decided against.
- **Mac App Store.** The store updates the app, but it needs the Developer Program and
  App Review, and agent.md §15 puts direct distribution first.
- **Homebrew cask.** Useful as an extra channel; it updates only for Homebrew users, and
  only when they run `brew upgrade`.
- **A custom installer.** It would repeat Sparkle's signature checking and sandbox
  installer work with less review behind it.
