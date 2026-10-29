# Integrate Sparkle 2.10.0 for macOS auto-update, disabled by default

Plainsong's alpha builds are manual downloads. U1 of `docs/auto-update-plan.md` adds the
updater behind a build setting so a later signed release can turn it on without another
architectural pass. `PLAINSONG_UPDATES_ENABLED` defaults to NO. That build does not
create or start `SPUStandardUpdaterController`, does not schedule checks, and does not
request the feed. The Check for Updates menu item and the Settings toggles are omitted.
U1 exercises the YES path only through a fake client in tests. Real Sparkle
rejects the empty `SUPublicEDKey` (`SUSigningInputStatusInvalid`, "The EdDSA
public key is not valid") and does not run a check until U2 fills the key and feed.

U-D1 (Sparkle 2) and U-D3 (Sparkle's own default behavior) are adopted. U-D3 applies
only when the flag is YES: the second-launch permission prompt stays Sparkle's
(`SUEnableAutomaticChecks` is unset), automatic download stays off
(`SUAutomaticallyUpdate` is unset), and system profiling stays off
(`SUEnableSystemProfiling` is unset). U-D2 and U-D4 through U-D7 remain for the owner.
`SUFeedURL` and `SUPublicEDKey` are present and empty until U2. The README limitation
"no auto-update" stays until U3, because the shipping flag is still NO.

Sparkle is a new Swift dependency (agent.md §2, §17.7). It is pinned to git
revision `eef1a539a373c1f1a320624b1130fc5de7b2e100`, which is tag 2.10.0, published
2026-09-13. That commit's `Package.swift` checksum for
`Sparkle-for-Swift-Package-Manager.zip` is
`17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`, verified against
the downloaded zip. `exactVersion` is not used: the app's `Package.resolved` is not
committed, so a moved tag could change the binary. 2.10.1 was published 2026-10-25,
less than two weeks before this change, so it is not eligible; revisit it in U3
after its observation window. Only the macOS App target links the `Sparkle`
product. `Scripts/check-sparkle-layering.sh` fails `make test-packages` if
`git grep -n -w Sparkle -- Packages` matches, and it requires this revision.
The beta toggle is not a Sparkle property; `allowedChannels(for:)` returns
`["beta"]` or an empty set, and the choice is stored in `PlainsongReceivesBetaUpdates`.
`feedURLString(for:)` returns the bundle's `SUFeedURL`, or an empty string when the
key is missing. Sparkle 2.10.0 uses a nil delegate result as a signal to fall back
to user defaults (`-[SPUUpdater retrieveFeedURL:]`); an empty string does not fall
back. After the controller is created, `clearFeedURLFromUserDefaults()` removes a
legacy `SUFeedURL` default. The 2.10.0 package `LICENSE` (MIT, plus bsdiff,
sais-lite, orlp/ed25519, and the SUSignatureVerifier notice) is copied to
`docs/third-party/Sparkle-2.10.0-LICENSE.txt`.

Sandboxing follows Sparkle's guide. `SUEnableInstallerLauncherService` is YES.
`SUEnableDownloaderService` is not set, because the app already has
`com.apple.security.network.client`. The entitlements add
`com.apple.security.temporary-exception.mach-lookup.global-name` for
`$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`.
Those Info.plist and entitlement entries stay on a `PLAINSONG_UPDATES_ENABLED=NO`
build. They do not create the updater, but the mach-lookup names are temporary
exceptions and would need a separate pass before a Mac App Store submission.
`Scripts/release.sh` re-signs Installer.xpc, Downloader.xpc
(`--preserve-metadata=entitlements`), Autoupdate, Updater.app, and Sparkle.framework,
then the app, preserving the entitlements Xcode already expanded. Signing does not
use `--deep`. The Developer ID path adds `-o runtime --timestamp`. Each of those
items is checked with `codesign --verify --strict`, and the finished app is then
checked with `codesign --verify --deep --strict` (verification only). If the shipped
`PLAINSONG_UPDATES_ENABLED` is not `NO`, the plist must contain a 32-byte EdDSA
public key, `https://w3d-su.github.io/plainsong/appcast.xml`, `SURequireSignedFeed`,
and `SUVerifyUpdateBeforeExtraction`. That feed URL is the release guard's expected
host. U-D4 is still the owner's decision, so U2 changes the constant if the host
changes. U1's `NO` build does not have to satisfy it.

Install and relaunch goes through the normal quit path, so this change does not bypass
a refused termination. Sparkle 2.10.0 (`eef1a539a373c1f1a320624b1130fc5de7b2e100`)
sends the quit from `-[InstallerProgressAppController sendTerminationSignal]`
(`Sparkle/InstallerProgress/InstallerProgressAppController.m`, the method that calls
`-[NSRunningApplication terminate]`). Its comment says it is an Apple quit event the
app or user can delay or cancel. `SPUUserDriver.h` documents the same for
`showInstallingUpdateWithApplicationTerminated:retryTerminatingApplication:`: if the
app has not terminated, a quit event is sent, and cancellation or delay leaves the
install waiting. `SPUStandardUserDriver.m` repeats that the quit event can always be
canceled or delayed, and closes the status window instead of forcing the process out.
Nothing under `Sparkle/`, `Autoupdate/`, or `InstallerLauncher/` calls
`forceTerminate`. `-[NSRunningApplication terminate]` is the normal Quit path, which
`NSApplication` delivers to `applicationShouldTerminate`. Plainsong's implementation
returns `.terminateCancel` when `prepareForTermination()` is false. That method refuses
before flushing when recovery state cannot be loaded, an editor source is still pending,
an image insertion blocks quit, a recovery copy cannot be persisted, or a workspace mutation
is in progress. `flushAutosaveIfNeeded()` runs only after those checks. A dirty session whose
saved recovery revision still does not match then cancels termination too, so a save that
cannot finish still blocks the update. Recovery copies and the window-state quit rules
therefore still run. The updater delegate implements `allowedChannels(for:)` and
`feedURLString(for:)`. It does not postpone relaunch, install immediately, or
terminate the process itself.

Typing is unaffected on the default build. The updater is not instantiated, so Sparkle
adds no timer, no feed request, and no observer to the editor. No code was added to
`DocumentSession`, EditorKit, highlighting, or preview. U-G8 stays open until U3 runs
the updater and records a measurement; this change does not add a `docs/perf/` entry
because nothing on the typing path was measured or modified.

Alternatives: a release-check that only links to the GitHub download (rejected: it is
not auto-update; it remains the fallback if Sparkle is later removed). The Mac App
Store (rejected for this step: agent.md §15 ships direct distribution first, and the
store needs the Developer Program and review). A Homebrew cask (rejected as the only
channel: it updates only Homebrew users, and only when they upgrade). A custom
installer (rejected: it would reimplement Sparkle's signature checks and sandboxed
install with less review). Leaving Sparkle unpinned or taking 2.10.1 (rejected: the
plan requires an exact 2.x release at least two weeks old).

Supersedes: the archive row dated 2026-07-02, "no auto-updater" for alpha, only for
the disabled integration. The user-facing alpha behavior is unchanged while the flag
stays NO.
