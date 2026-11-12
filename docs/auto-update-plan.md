# Auto-Update Plan (macOS)

> **Status: U1 adopted U-D1 and U-D3, 2026-10-29. V5 was decided on 2026-11-10: in-app
> updates are Must for 1.0 (`docs/decisions/2026-11-10-release-1.0-scope.md`).**
> U-D2 follows from V5 and V4 (unsigned DMG). The owner adopted U-D4, U-D5, U-D6 and
> U-D7 as proposed on 2026-11-10
> (`docs/decisions/2026-11-10-auto-update-feed-secret-and-signed-feed.md`). Adding Sparkle is a new Swift dependency, so the
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
  with every release. `MARKETING_VERSION` was `0.1.0` for alpha.1–alpha.5. Since V6 a
  tagged build takes it from the tag: `v0.9.0-beta.1` is `0.9.0`, and the prerelease
  suffix stays in the tag
  (`docs/decisions/2026-11-12-release-marketing-version-from-tag.md`). Sparkle compares
  `CFBundleVersion`, so the existing numbering works unchanged. Two betas of one version
  share a display version, and Sparkle's update dialog then adds the build numbers:
  "0.9.0 (312) is now available—you have 0.9.0 (305)".
- Users on alpha.1–alpha.5 have no updater. They must install the first build that has
  one by hand; every build after that updates itself.

## 2. Owner decisions

| ID | Question | Proposed answer | U1 |
|---|---|---|---|
| U-D1 | Mechanism | **Sparkle 2** (alternatives in §7) | 已採用 |
| U-D2 | Ship before or after Developer ID signing? | **Before, on unsigned builds.** V4 ships unsigned and V5 makes updates Must (`docs/release-1.0-scope.md` §1). The original proposal was after P1/P2; the 2026-11-10 probe in §5 removed its main reason | 已採用 (2026-11-10, from V4 and V5) |
| U-D3 | Default behavior | Ask on second launch (Sparkle's default); "Automatically check" on, "Automatically download and install" off until 1.0 | 已採用 |
| U-D4 | Feed host | `appcast.xml` on GitHub Pages (`gh-pages` branch), written by the release workflow | 已採用 (2026-11-10) |
| U-D5 | Channels | One stable feed plus a `beta` channel (`sparkle:channel`) that users opt into in Settings. Prereleases go to `beta` only | 已採用 (2026-11-10) |
| U-D6 | Signing secret in CI | Store the EdDSA private key as a GitHub Actions secret, used only by the tag job. This reverses the 2026-07-02 "no secrets" rule | 已採用 (2026-11-10) |
| U-D7 | Feed signing | Turn on `SURequireSignedFeed` (and its prerequisite `SUVerifyUpdateBeforeExtraction`) from the first release | 已採用 (2026-11-10) |


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
  and `SUVerifyUpdateBeforeExtraction`. The key check matches Sparkle's decoder:
  Foundation's whitespace trim, no padding repair, and no interior whitespace.
  Non-zero trailing base64 bits are accepted. The feed check strips quotes only.
  CI runs the same guard on the Debug Info.plist after the ui-performance build.
  The installer-launcher key and the mach-lookup
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
2. `Scripts/make-appcast.sh` runs Sparkle's `generate_appcast` over a folder that holds
   the published `appcast.xml` (fetched from `gh-pages`) and the new DMG. It signs the
   DMG, and signs the feed when the app sets `SURequireSignedFeed`, with the EdDSA key
   from the `SPARKLE_ED_PRIVATE_KEY` secret, passed on standard input. The script fails
   unless the new item's download comes out signed: `generate_appcast` only warns, and
   leaves the download unsigned, when the secret is not the private half of the app's
   `SUPublicEDKey`. Earlier items stay
   in the feed without their DMGs. Release notes are GitHub's generated notes for the
   tag, embedded in the item as Markdown. Delta updates are not generated, because the
   job has only the new DMG.
3. The tag job keeps creating the **draft** GitHub Release and attaches the signed
   `appcast.xml` to it. Publishing the feed is a second, manually dispatched workflow
   (`publish-appcast`) that the owner runs after publishing the release. Users therefore
   never receive a build the owner has not released. It holds no key: it checks that
   the release is published, that the feed names that tag's download and only this
   repository's releases, and that in each channel of the published feed its newest build
   is at least the published one, then commits `appcast.xml` to `gh-pages`. A feed is
   built from the feed that was published when its tag ran. Publish each release's feed
   before pushing the next tag; a feed built earlier lacks that release, the check
   refuses it, and re-running the tag's Release workflow rebuilds it.
4. `generate_appcast` takes each item's `sparkle:minimumSystemVersion` from the app's
   `LSMinimumSystemVersion` (14.0, agent.md §1). A tag with a hyphen (`v0.9.0-beta.1`)
   carries `<sparkle:channel>beta</sparkle:channel>` (U-D5), so only users who turned on
   Receive beta updates are offered it.
5. While `SPARKLE_ED_PRIVATE_KEY` or the app's `SUPublicEDKey` is absent the tag job
   builds no feed, and it fails if the build has updates on. It also fails when
   `gh-pages` exists and cannot be read, so a feed is never built without the published
   one. `Scripts/make-appcast.sh --self-test` runs on every release
   run with a throwaway key (`make test-appcast` locally).

### 3.5 Keys

- Generate the EdDSA pair once with Sparkle's `generate_keys` on the owner's Mac. Keep
  the private key in the login Keychain plus an offline backup, and copy it into the
  Actions secret (U-D6). The public key goes into `Info.plist`.
- Sparkle documents that rotating EdDSA keys needs a Developer ID-signed disk image, and
  that changing the Apple certificate and EdDSA key in the same release is unsupported.
  **Never change both at once.** Losing the private key strands every installed copy:
  with V4's unsigned builds there is no Developer ID image to rotate through.

## 4. Work packages

| PR | Scope | Owner needed? |
|---|---|---|
| U1 | Decision entry; Sparkle package; updater controller; menu item; Settings toggles; Info.plist keys and entitlements; release-script re-signing; unit and hosted tests (§5) | No. `SUFeedURL` and `SUPublicEDKey` are empty strings until U2. YES is covered with a fake client, not a live Sparkle check |
| U2 | `make-appcast.sh`, the feed step in `release.yml`, and the `publish-appcast` workflow (#257). U2b: `SUFeedURL`, `SUPublicEDKey`, `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` in every build, and `PLAINSONG_UPDATES_ENABLED=YES` in release builds (#258). README update with U3 | Done on 2026-11-10: the owner generated the key pair and added the `SPARKLE_ED_PRIVATE_KEY` secret |
| U3 | End-to-end update gate (§5 U-G4–U-G7) against a local test feed, then against the real feed with unsigned builds | **Yes**: the owner runs the clean-machine pass |

U1, U2 and U2b are merged (#232, #257, #258). U3 is next: it needs the first tagged
release, which is the first build with updates on.

## 5. Gates

U1 closes U-G1 and U-G2. U-G3's unsigned path passed on 2026-10-29:
`PLAINSONG_UNSIGNED=1 make release` ran `codesign --verify --strict` on Installer.xpc,
Downloader.xpc, Autoupdate, Updater.app, Sparkle.framework, and the app, then
`build/release` was deleted. The Developer ID path is the same signer plus
`-o runtime --timestamp` and stays open until a signed release, because this machine has
no Developer ID identity. U-G4–U-G9 stay open for U2 and U3.

Unsigned Gatekeeper probe, 2026-11-10 (owner-run, macOS 27, Apple Silicon). Two Release
builds of `main` at `2a555d9` (`CFBundleVersion` 9001 and 9002, arm64 only, ad-hoc
signed and re-signed as `Scripts/release.sh` does, bundle identifier
`app.plainsong.editor.updatetest`, `PLAINSONG_UPDATES_ENABLED=YES`). The 9001 disk image
carried a `com.apple.quarantine` attribute, and the steps had the owner drag the app out
with Finder and approve it once with Open Anyway; whether that first launch was blocked
was not recorded. Check for Updates… offered 9002 from
`http://localhost:8765` (the test build added `NSAllowsLocalNetworking`), with the
archive signed by a throwaway EdDSA key. After Install and Relaunch the app ran as
0.1.9002 with no Gatekeeper prompt, and a later launch from Finder had none either. This
is one update on one Mac. It does not close U-G4: the feed was not HTTPS, and bookmarks,
recents, preferences and the recovery store were not checked. The builds, key and feed
were deleted afterward.

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
| Unsigned (ad-hoc) builds: the sandboxed download is quarantined, and the updated app may hit Gatekeeper's "Open Anyway" again after every update | Did not happen in the 2026-11-10 probe (§5): one update, one Mac, macOS 27. Repeat it in U3 on the real feed, across two consecutive updates and on a second Mac, before the README drops "no auto-update" |
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
