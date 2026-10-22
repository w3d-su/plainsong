# An edit refreshes the active workspace search only after a typing pause, and only while Search shows

With a query active, every edit to a workspace document called `startWorkspaceSearch`.
Each call cancelled the running search, replaced `workspaceSearchState` with empty results
(a whole-window `AppState` publish and a flash of "Waiting…" per keystroke) and, 200 ms
after the last edit, re-read every candidate file, re-read the ignore files and hashed every
searched file. It did this even while the Files navigator was showing, because switching to
Files keeps the query.

Now `restartActiveWorkspaceSearchAfterRelevantEdit` schedules
`WorkspaceSearchEditRefresh`: the restart runs once edits have paused for 500 ms, so typing
touches no search state. While the Files navigator shows, the edit only marks the search
for a refresh, which runs when Search shows again (`selectWorkspaceSidebarMode`,
`focusWorkspaceSearch`). Any search start (a new query, a reload refresh) cancels a waiting
edit refresh. The refresh itself is the existing restart with fresh dirty overlays, so the
results it shows are unchanged.

In the same lane: `applyWorkspaceSearchFileResult` places each result by binary search in
the path-sorted array instead of a linear lookup plus a full re-sort per event, which was
quadratic over a large result set. The search pipeline computes a file's SHA-256 content
fingerprint only when the file emits a result, instead of for every searched file.

Alternatives: keep the previous results visible and re-match only the edited session's
overlay (deferred: the pipeline's overlay, fingerprint and navigation contracts would all
change, and the pause already removes the per-keystroke cost); restart immediately but skip
the state reset (rejected: the old search would keep emitting results for the pre-edit text);
pause only on a collapsed sidebar (rejected: switching to Files is the common way to leave a
query behind); batch result events per run-loop turn (deferred: each event is already O(log n)
plus the publish).
