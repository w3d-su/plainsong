# Auto-update: GitHub Pages feed, the signing key as a CI secret, and a signed feed

Date: 2026-11-10. Owner decisions U-D4, U-D6 and U-D7 in `docs/auto-update-plan.md` §2,
adopted as proposed.

## Decision

- **U-D4.** The appcast is `appcast.xml` on GitHub Pages (`gh-pages` branch), at
  `https://w3d-su.github.io/plainsong/appcast.xml`, written by the release workflow.
- **U-D6.** The EdDSA private key is stored as a GitHub Actions secret and used only by
  the tag job that signs the update and the feed. This reverses the 2026-07-02 rule that
  the release workflow uses no secrets.
- **U-D7.** `SURequireSignedFeed` and its prerequisite `SUVerifyUpdateBeforeExtraction`
  are on from the first release that has updates.

U-D5 (a `beta` channel) is not decided here.

## Why

- U-D4: the repository is public and already on GitHub, so Pages adds no host, account or
  cost, and the feed URL is already the one `Scripts/check-shipped-update-configuration.sh`
  expects.
- U-D6: 1.0 needs in-app updates (V5), and an update must be signed where it is built.
  Signing on the owner's Mac instead would make every release depend on that machine and
  would put a hand step between the tagged build and what users receive. The 2026-07-02
  rule existed because the unsigned pipeline needed no secret; it now needs one.
- U-D7: with unsigned builds (V4) the EdDSA key is the only thing that authenticates an
  update. Signing the feed as well means a tampered or replaced `appcast.xml` is rejected
  before any archive is downloaded.

## Alternatives considered

- Attaching `appcast.xml` to GitHub Releases: there is no stable URL for "the latest
  feed" that does not move with each release.
- Signing locally and keeping CI secret-free: rejected for the reason under U-D6.
- An unsigned feed, with only the archive signed: Sparkle allows it, but it leaves the
  feed's contents (versions, release notes links, minimum system version) unauthenticated.

## Consequences

- The secret is scoped to the tag job. Pull request workflows never receive it, and no
  job that runs code from a pull request may be given it.
- The private key has an offline backup outside GitHub. Losing it strands every
  installed copy, because key rotation needs a Developer ID-signed image and V4 ships
  unsigned.
- `.github/workflows/release.yml`'s "No secrets" comment and
  `docs/release-engineering-plan.md`'s matching sentence change in U2, with the workflow.
