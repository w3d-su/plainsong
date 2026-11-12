# Auto-update U2b: release builds turn updates on; other builds stay off

Date: 2026-11-10. Follows V5 (in-app updates are Must) and U-D2 (on unsigned builds).

## Decision

- `project.yml` now carries the feed URL
  (`https://w3d-su.github.io/plainsong/appcast.xml`), the public half of the owner's
  EdDSA key, `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` in every build's
  Info.plist.
- `PLAINSONG_UPDATES_ENABLED` stays NO in `project.yml`. `Scripts/release.sh` passes
  `PLAINSONG_UPDATES_ENABLED=YES` to its build, so only release builds create an updater.

## Why

- A development or hosted-test build with the flag on would start a real `SPUUpdater`:
  it would request the feed, and on a second launch ask the developer about automatic
  checks. Tests would then depend on the network and on the published feed.
- Putting the switch in the one script that produces what users install keeps the
  guard's meaning: `Scripts/check-shipped-update-configuration.sh` runs on that build and
  refuses it unless the key, feed and signed-feed keys are all right.
- The four values are inert while the flag is NO, so keeping them in every build means a
  release differs from a development build by one setting.

## Alternatives considered

- YES in `project.yml`: rejected for the first reason above.
- A separate Release-configuration value in `project.yml`: a local Release build
  (`xcodebuild -configuration Release`, performance runs) would then update too.

## Consequences

- The first tagged release after this lands has a working updater. With the U2 pipeline
  (#257) merged, that tag run fails unless the `SPARKLE_ED_PRIVATE_KEY` secret exists, so
  an updating build cannot ship without a feed. Without #257 it would ship with no feed:
  merge #257 first.
- The public key is now fixed in shipped builds. Losing the private key strands them
  (`docs/auto-update-plan.md` §3.5).
- The README keeps "No auto-update" until U3 has run against the real feed.
