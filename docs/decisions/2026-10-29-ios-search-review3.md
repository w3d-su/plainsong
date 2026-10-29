# iOS search provider refreshes and stale refusal caching

Date: 2026-10-29

An unchanged-tree workspace refresh reuses cached search reads and schedules through
the existing 200 ms debounce. Per-file `resourceChanged` notices still invalidate
that path before scheduling, so a burst of file and root metadata notices rereads
only changed files. A changed tree, an explicit query, or a different grant still
starts a fresh search. This replaces the unchanged-tree full invalidation described
in `2026-10-29-ios-review-follow-up.md`.

The production root presenter reports child changes, appearances, deletions and moves
as per-path notices. Root and ubiquity-attribute changes refresh the tree separately;
they do not by themselves prove that every file's text changed. Keeping those cached
reads avoids full-folder reads during iCloud metadata activity. Actual callback
frequency on an iCloud folder still needs physical-device observation.

Every cached size or encoding refusal checks the captured cache epoch, just like
successful reads. An invalidation during a read cannot restore its obsolete refusal.
When the bounded truncation probe encounters a changed or escaped grant, it stops and
reports "The folder changed. Search again.", matching the ordinary search pass.

The PDF export regression keeps its rendered teal-pixel assertion. It no longer
requires an image at the page's first XObject level: a Form XObject can contain the
same correctly rendered image at a deeper level.

Alternatives considered: clearing the whole cache on every root refresh retains
unnecessary reads under provider metadata churn. Only debouncing that full clear
still rereads unchanged files after each settled burst. Recursively inspecting PDF
Form resources adds structural machinery without improving the existing visual
assertion that the fixture image actually appears.

Validation includes original-code regression failures for changed grants during
probing, invalidation during both refusal types, and unchanged-tree refresh reads.
The unchanged-refusal control still reuses cached refusals. Simulator app tests
cover the fixes and grant-backed HTML/PDF export; device printing and iCloud callback
frequency remain separate owner checks.
