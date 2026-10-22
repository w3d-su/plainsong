# In the default Markdown-only mode the workspace scan skips generated and vendored directories

Opening an Astro or Next.js project root enumerated all of `node_modules`, `dist`, `.next`
and similar trees. The scan pays an anchored no-follow inspection for every entry, and these
trees are most of a web project's entries. Their `README.md`s also showed up in the Files
tree and in completion paths. Search already ignored them (`WorkspaceSearchCandidates`).

The owner chose (2026-10-22) to skip them unless "Show all files" is on. The list is now one
definition, `WorkspaceIgnoredDirectories` (`.git`, `node_modules`, `.build`, `.next`, `.astro`,
`deriveddata`, `dist`, `build`, case-insensitive), shared with Search.
`WorkspaceDirectoryScanner.snapshotCapture(root:pruning:)` skips such a directory and
everything under it before inspecting it. `AppState` passes `.ignoredDirectories` while
`showAllFiles` is off and `.none` when it is on. Toggling the setting already triggers a
rescan. A directory on the way to a managed session's file (the current document or a
cached session, in every spelling that may name it inside the root) is still scanned, so an
open document opened earlier in "Show all files" mode does not look missing after the
rescan. On a synthetic Astro project with 21,266 entries (800 packages in `node_modules`) the
capture took 2,658 ms unpruned and 8.2 ms pruned
(`docs/perf/2026-10-22-markdown-only-scan-pruning.md`).

Alternatives: show ignored directories as collapsed nodes loaded on expansion (rejected by
the owner as more work for little use in a blog editor); filter them only when building the
tree (rejected: the cost is the scan's per-entry inspection, not the tree); prune by path
component everywhere like Search, including files named `build` (rejected: only directories
are generated trees); drop retained-session handling (rejected: switching back to
Markdown-only with a `node_modules` README open would raise the missing-file prompt).
