# Auto-update U2: the tag job signs the feed, a separate workflow publishes it

Date: 2026-11-10. Implements U-D4, U-D6 and U-D7
(`docs/decisions/2026-11-10-auto-update-feed-secret-and-signed-feed.md`, recorded with the
1.0 scope) as the pipeline in `docs/auto-update-plan.md` §3.4.

## Decision

- **Signing happens in the tag job, publishing does not.** `release.yml` fetches the
  published `appcast.xml` from `gh-pages`, runs `Scripts/make-appcast.sh` to add and sign
  the new DMG, and attaches the result to the draft release. `publish-appcast.yml`, run by
  hand, copies that file to `gh-pages`. It has no key.
- **The key reaches one step.** `SPARKLE_ED_PRIVATE_KEY` is in the environment of the
  "Build the update feed" step only, on tag runs only, and goes to `generate_appcast` on
  standard input. `release.yml` has no `pull_request` trigger.
- **No key, no feed.** Without the secret the tag job skips the feed. It fails instead if
  the build has `PLAINSONG_UPDATES_ENABLED` on, so an updating build cannot ship without
  a feed.
- **This PR does not turn updates on.** `SUFeedURL`, `SUPublicEDKey`, the two signed-feed
  keys and the flag change in U2b, when the owner has generated the key pair.
- **No delta updates yet**, and release notes are GitHub's generated notes for the tag,
  embedded as Markdown.
- **A tag with a hyphen goes to the `beta` channel**, as §3.4 proposed. U-D5 is still the
  owner's to decide and can change this one rule.

## Why

- A signed feed cannot be edited after signing, so the job that holds the key has to
  produce the final file. Keeping the publish step keyless means the workflow a person
  triggers by hand, with a free-text input, can do no more than choose which
  already-signed feed is live.
- The publish step refuses a draft release, a feed that does not name the tag's download,
  an item that downloads from anywhere but this repository's releases, and a feed older
  than the published one. The last check exists because publishing an earlier release's
  feed would hide the newer release from every user.
- `generate_appcast` keeps earlier items when their DMGs are absent (checked with Sparkle
  2.10.0), so the job needs only the previous feed and the new DMG. Deltas would need the
  previous DMGs downloaded as well; a 10 MB DMG does not justify that yet.
- Embedded notes are covered by the feed's signature. Linked notes would be a second
  signed file to host.

## Alternatives considered

- Signing in `publish-appcast`: it would give the secret to a manually dispatched workflow
  with a text input, and the feed would be signed after the owner's review instead of
  before.
- Committing to `gh-pages` from the tag job: users would be offered a build while its
  release is still a draft.
- A feed that lists only the newest build: stable users would lose their newest stable
  item whenever a beta is published after it.

## Verification

- `Scripts/make-appcast.sh --self-test` builds four minimal apps and checks, with a
  throwaway key and the pinned Sparkle tools: two successive releases produce a feed with
  both items; the first keeps its channel and URL without its DMG; release notes are
  embedded; a build older than the feed is refused; a malformed tag is refused; the
  signed feed verifies and a changed one does not; an app without `SURequireSignedFeed`
  gets an unsigned feed; and the key appears in no log. It passed locally on macOS 27
  against Sparkle 2.10.0. `release.yml` runs it on every tag and dispatch run.
- The publish workflow's feed check was run locally against six sample feeds (accept:
  newer feed, first feed; refuse: stale, wrong tag, foreign download, empty).
- Not run: either workflow on GitHub. The first dispatch run of `release.yml` exercises
  the self-test there; the tag path needs the secret and a tag.
