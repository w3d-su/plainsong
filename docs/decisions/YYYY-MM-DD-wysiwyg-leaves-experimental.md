# WYSIWYG leaves Experimental and becomes a normal layout choice, on by default

> **Draft, pending the maintainer's sign-off.** Rename this file with the approval date
> and fill in the dogfood evidence before the PR merges.

Approved: YYYY-MM-DD by <maintainer>, after the dogfood sign-off in
`docs/wysiwyg-dogfood-checklist.md` (record: <link>).

Why: every gate in `docs/wysiwyg-release-checklist.md` A-F, `docs/image-thumbnail-gates.md`
I0-I10 and `docs/link-folding-gates.md` L1-L9 was re-verified against `origin/main`
`1428bf1` on 2026-10-24 (`docs/wysiwyg-promotion-audit.md`), after STTextView 2.4.1, the
typing-path and cache-trimming work, the EditorKit gutter, whole-source resets,
Replace/Find and the iOS move of the fold model into SyntaxKit. That audit added gates for
cache trimming, the production viewport and pointer hits beside the gutter. The
click-layout fix (<PR link>) removed the last known limit: a WYSIWYG click no longer lays
out the whole document. The owner reran the actual Zhuyin/Pinyin harness on <date>
(<result>) and dogfooded WYSIWYG for real writing.

What changes: `Plainsong.settings.experimentalWYSIWYGEnabled` now defaults to `true`, so
WYSIWYG is offered in the `⌘⇧P` cycle (source + preview → source only → WYSIWYG) and the
toolbar layout picker without visiting Settings. The first-launch layout stays source only,
and a persisted layout is restored as before. The Settings switch stays as the kill switch,
relabeled "WYSIWYG mode" without "Experimental"; turning it off, or a mechanism failure,
still falls back to source only without touching text (D.3). The key keeps its name so a
`false` stored by someone who turned the Experimental mode off is kept. The View menu,
toolbar, Settings copy, fallback banner and README drop the Experimental label. Construct
scope (checklist §E) is unchanged.

Alternatives: making WYSIWYG the first-launch layout was not chosen: agent.md §13 keeps
WYSIWYG as one stop in a three-mode cycle with the two-pane mode available forever, and
changing what a new user sees first is a separate product decision the dogfood can inform
(one line in `AppState.restoreLayoutMode`). Removing the Settings switch was rejected
because D.3 requires a kill switch. A new key that ignores old values was rejected because
it would turn WYSIWYG back on for people who had turned it off. Renaming the Swift
identifiers (`experimentalWYSIWYGEnabled`, `isExperimentalWYSIWYGAvailable`) and the
EditorKit `_development*` parameters is left to a follow-up to keep this change small.

Supersedes: the 2026-06-27 archive row "Phase 2 WYSIWYG mode plumbing ships behind an
off-by-default Experimental kill switch" (its off-by-default part), and the "only in the
off-by-default Experimental mode" scope of the 2026-07-06 link-folding and 2026-07-12
image-thumbnail rows.
