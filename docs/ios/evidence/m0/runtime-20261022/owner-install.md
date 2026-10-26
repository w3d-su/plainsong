# Owner installation and result recording

This package is the standalone M0 prototype, minimum iOS/iPadOS26, supporting
both iPhone and iPad. It is not the complete Plainsong iOS app. All owner gates
start OPEN. Use the public `m0.md` fixture and disposable local/iCloud copies.

## A. Re-sign this exact delivered IPA

1. Verify `SHA256SUMS` in the extracted owner-kit directory. The original unsigned
   IPA digest must be `3a7ec6b11151a79a4279680d0152fd2bc1765652255605674ec129e0b708adcf`.
2. Use your own chosen local signing workflow. Supply its compatible development
   identity/profile, bundle-ID/team settings and device authorization locally.
   Follow that tool's validation and installation instructions. No signing tool
   has been selected or exercised by this delivery, so no tool-specific success
   or command sequence is claimed.
3. Confirm the tool is signing the delivered `PlainsongIOSM0-unsigned.ipa`.
   Xcode's Run action builds from source; it does not re-sign this IPA.
   After signing, retain the signed artifact digest separately from the original.
4. Pair each physical device with the Mac as required by your workflow. Apple
   documents [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
   for development-signed installations. Follow the device's pairing/enable/restart
   prompts. Use a cable for the iOS/iPadOS26 minimum-OS run; the current Xcode guide
   scopes its newer wireless pairing flow to OS27 and later.
5. Install and launch on both an iPhone and an iPad. Open a real local Files fixture
   in place, edit/save/reopen it, then repeat with iCloud Drive. Only actual results
   close the relevant device gate.

Keep credentials, certificates, provisioning profiles, raw bookmarks, device IDs,
private URLs and account details outside Git and shared artifacts. The owner forms
record tool name/version/method and redacted outcomes, not secrets.

## B. Optional source build using Xcode

This is a separate installation route. It produces a new signed binary and does
not prove re-sign/install of the delivered IPA. Keep its own source/build/installed
artifact identity; do not mark the exact-IPA M0-Install result PASS from it.

Use an isolated checkout of `e20162e5c2402800e84cf1f68ae4787535228c50` and generate the prototype project from
`Prototypes/iOSM0/project.yml`. The manifest intentionally sets
`CODE_SIGNING_ALLOWED=NO`. For an owner-only source run, enable signing locally
for the app target (Code Signing Allowed / `CODE_SIGNING_ALLOWED=YES`), select your
team and unique bundle ID in Signing & Capabilities, enable automatic signing,
choose the paired device and Run. These local generated-project settings are
private and disposable; regeneration restores the unsigned default. Do not
change the root app target, commit signing data, or assume `run.sh ipa` signs.

Apple's [run-on-device guide](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
explains account/team/unique bundle-ID and automatic provisioning.
[Device Hub](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub)
covers pairing; [build settings](https://developer.apple.com/documentation/xcode/build-settings-reference)
describes Automatic/Manual signing. These references were checked through Context7
on 2026-10-22. No personal signing or physical installation was attempted here.

## Shared lock on this Mac

For manual Xcode generation, signing/install and device runs, acquire the canonical
lock for the entire manual session:

```sh
lockf -t 0 -k /private/tmp/plainsong-xcodebuild-test.lock /bin/zsh
# Generate/open/sign/install/run manually while this shell holds the lock.
# Exit this shell after the manual session.
```

Do not invoke `Prototypes/iOSM0/Scripts/run.sh` from that shell: it takes the same
lock itself. A busy lock is a scheduling wait. Do not reset shared simulators or
interrupt unrelated test tasks to obtain it.

## Evidence and recovery

Use a separate `owner-results/<family>/<gate>.json` copy per actual attempt,
input method/provider where needed. Source and original unsigned IPA/fixture hashes
are prefilled; device model/OS, timestamps, signing method, real steps and results
remain empty. Record expected and actual source UTF-16, selection/marked range,
dirty/saving/conflict state and readback-confirmed recovery, with the redacted
probe log and public-fixture recording.

In the prototype, Fixture makes an app-private test copy. File and Folder select
real in-place grants; use those controls for Files/iCloud acceptance. Delay enables
the N/N+1 save probe; Inspect shows source/selection; Recovery reads saved recovery;
Export log shares redacted events. View switch is a presentation probe, not the
product Markdown preview. Follow `manual-checklist.md` for the full sequences.

On content loss, composition/selection/Undo damage, unauthorized overwrite or
failed recovery, record FAIL, preserve the attempt and local content, and stop
production composition. Save copy writes a separate local file and verifies its
bytes; it does not resolve the original conflict or establish original-file save.
A source build or re-sign operation may change identifiers/entitlements: keep the
original receipt and record those changes locally. Missing evidence stays OPEN.
