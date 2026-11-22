# A tagged release build takes its marketing version from the tag

Date: 2026-11-12. Follows V6 (the release is `1.0.0`, with `0.9.x` betas before it, all
unsigned DMGs) and extends P0.5 in `docs/release-engineering-plan.md`.

## Decision

- A release tag is `vX.Y.Z` or `vX.Y.Z-<prerelease>`: `v1.0.0`, `v0.9.0-beta.1`,
  `v0.1.0-alpha.5`. `X`, `Y` and `Z` are integers without leading zeros. The prerelease
  part is groups of letters and digits separated by `.` or `-`.
- The build's `MARKETING_VERSION` (`CFBundleShortVersionString`) is the tag's `X.Y.Z`.
- The prerelease part is not put in the app. It stays in the git tag, the GitHub Release
  and the download URL, and its hyphen is what puts the build on Sparkle's `beta` channel
  (`release.yml`). `v0.9.0-beta.1` and `v0.9.0-beta.2` are both "0.9.0" and differ by
  build number: About shows "Version 0.9.0 (N)" and the DMG is
  `Plainsong-0.9.0-N-unsigned.dmg`.
- `Scripts/release-version.sh` holds the rule, and `Scripts/release.sh` calls it before
  `xcodegen` and the build. The first of these that is set wins: an explicit
  `PLAINSONG_MARKETING_VERSION`; a tag, from `PLAINSONG_RELEASE_TAG` or from
  `GITHUB_REF_NAME` when `GITHUB_REF_TYPE` is `tag`; `0.1.0`, the `project.yml` value.
- A tag that is present and does not match stops the run before anything is built, even
  when `PLAINSONG_MARKETING_VERSION` is set. An explicit version must itself be `X.Y.Z`.
- The build number stays `git rev-list --count HEAD`.

## Why

- `MARKETING_VERSION` was fixed at `0.1.0` in `project.yml`, and `release.yml` passed
  nothing. A build from `v0.9.0-beta.1` would have called itself 0.1.0 in About, in the
  DMG name and in Sparkle's update dialog.
- `CFBundleShortVersionString` is documented as three period-separated integers, so
  `0.9.0-beta.1` cannot go there.
- Sparkle orders builds by `CFBundleVersion`, the commit count, so two betas with one
  display version still update in order. Sparkle 2.10.0's standard version display
  (`SPUStandardVersionDisplay.m`) appends the build numbers when the two display versions
  are equal: "0.9.0 (312) is now available—you have 0.9.0 (305)". This is read from the
  Sparkle source; it has not been seen in a running Plainsong.
- Reading `GITHUB_REF_NAME` in the script means `release.yml` changes by a comment only,
  and a local run with the same two variables takes the same path as the tag job.
- One spelling per version (no `v01.0.0`, no `v1.0`) keeps tag, DMG name and feed
  consistent. `v*` still triggers the workflow, so a tag such as `vnext` starts a run that
  fails at the build step with the tag named in the error.

## Alternatives considered

- Put the whole tag suffix in `CFBundleShortVersionString` (`0.9.0-beta.1`): rejected,
  because the key is three integers.
- A fourth component (`0.9.0.1` for beta.1): rejected. It is not three integers either,
  and it reads as a later version than `0.9.0`.
- A separate Info.plist key with the tag, shown in About: not done here. It needs an App
  change and a custom About panel; the build number already tells two betas apart.
- Put the tag in the DMG name: rejected. `Scripts/make-appcast.sh` and `release.yml`
  expect `Plainsong-<marketing>-<build>-unsigned.dmg`, and a dispatch run has no tag.
- Pass the version from `release.yml` (`PLAINSONG_MARKETING_VERSION: ${{ ... }}`):
  rejected. The parsing would live in workflow expressions that only a real tag run
  exercises, and a local run would not use them.
- Bump `MARKETING_VERSION` in `project.yml` by hand for each release: rejected. The tag
  and the file can disagree, and nothing would catch it.

## Consequences

- A dispatch run and a local `make release` without a tag still build as `0.1.0`, and so
  do development builds. Their build numbers are still current, so Sparkle treats them
  correctly, but About shows an old version. Changing the `project.yml` value is a
  separate decision.
- `release.yml` creates every release as a draft prerelease, `v1.0.0` included. The owner
  clears the prerelease mark when publishing a stable release.
- Verified on 2026-11-12: the script's self-test (in `make test-packages`), and one local
  `PLAINSONG_UNSIGNED=1 make release` with `GITHUB_REF_TYPE=tag` and
  `GITHUB_REF_NAME=v0.9.0-beta.1`. Not verified: a real tag run of `release.yml`, which
  needs a pushed tag.
