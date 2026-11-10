# Auto-update U2: the tag job signs the feed, a separate workflow publishes it

Date: 2026-11-10. Implements U-D4, U-D5, U-D6 and U-D7
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
- **No key pair, no feed.** Without the secret, or without a `SUPublicEDKey` in the app,
  the tag job skips the feed. It fails instead if the build has
  `PLAINSONG_UPDATES_ENABLED` on, so an updating build cannot ship without a feed.
- **A feed whose download is unsigned is an error.** `generate_appcast` signs the DMG
  only when the secret is the private half of the app's `SUPublicEDKey`; with any other
  key it warns, writes the item without a signature and exits 0. `make-appcast.sh` fails
  unless the new item carries `sparkle:edSignature`. The feed's own signature cannot
  catch this, because it is made and verified with the same private key.
- **This PR does not turn updates on.** `SUFeedURL`, `SUPublicEDKey`, the two signed-feed
  keys and the flag change in U2b, when the owner has generated the key pair.
- **No delta updates yet**, and release notes are GitHub's generated notes for the tag,
  embedded as Markdown.
- **A tag with a hyphen goes to the `beta` channel** (U-D5). With the default setting a
  user is offered nothing until the first tag without a hyphen.

## Why

- A signed feed cannot be edited after signing, so the job that holds the key has to
  produce the final file. Keeping the publish step keyless means the workflow a person
  triggers by hand, with a free-text input, can do no more than choose which
  already-signed feed is live.
- The publish step refuses a draft release, a feed that does not name the tag's download,
  an item that downloads from anywhere but this repository's releases, and a feed whose
  newest build in any channel of the published feed is older than the published one, or
  that has no item in that channel. A feed is built from the feed published when its tag
  ran. If two tags run before the first feed is published, the second feed lacks the
  first release; comparing only the newest build overall would accept a beta-only feed
  over a published stable item and leave stable users with no update. Re-running the
  second tag's Release workflow rebuilds its feed from the published one.
- For the same reason the tag job stops when `gh-pages` exists and cannot be read. Only
  `git ls-remote` reporting that the branch is missing counts as "no feed yet".
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
  gets an unsigned feed with a signed download; a key that does not match the app's
  `SUPublicEDKey` and an app without one are each refused for that reason; no disk image
  is left attached; and the key appears in no log. It passed locally on macOS 27
  against Sparkle 2.10.0. `release.yml` runs it on every tag and dispatch run.
- The publish workflow's feed check was run locally against thirteen sample feed pairs
  (accept: first feed, first feed over an empty one, beta added to a published stable,
  new stable keeping the beta, newer beta, the same feed again; refuse: beta-only over a
  published stable, stable-only over a published beta, older beta, older stable, wrong
  tag, foreign download, empty).
- `hdiutil attach` once returned success with the image attached and its volume not
  mounted (1 of 12 self-test runs on a loaded macOS 27 machine), and the image stayed
  attached. The script now checks the mount, attaches again up to three times, and
  detaches by device. A stand-in `hdiutil` that attaches without mounting confirmed the
  retry, the final error, and that no image is left attached.
- Not run: either workflow on GitHub. The first dispatch run of `release.yml` exercises
  the self-test there; the tag path needs the secret and a tag.
