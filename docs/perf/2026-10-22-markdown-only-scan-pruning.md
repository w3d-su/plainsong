# Workspace scan of a web project with and without ignored-directory pruning

- Date: 2026-10-22
- Commit: branch `phase3-workspace-scan-pruning` against `origin/main` `6bf644e`
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Apple M1 Pro 16 GB;
  `swift test -c release -Xswiftc -enable-testing` (WorkspaceKit); 1-minute load 13-37
- Fixture: generated in a temporary directory. 60 posts under `src/content/blog`, 800
  packages under `node_modules` (each `dist/` with 23 files plus a `README.md`), and 400
  chunks under `dist/_astro`: 21,266 entries in all. No agent.md §12 budget applies.
- Procedure: a temporary, uncommitted XCTest timed
  `WorkspaceDirectoryScanner.snapshotCapture(root:pruning:)` with `.none` and with
  `.ignoredDirectories(retaining: [])` on the same scanner. One unmeasured warm-up, then 10
  pairs with the order alternating per pair.
- Result: median 2,658 ms unpruned (21,266 entries) vs 8.2 ms pruned (63 entries), every
  pair. Unpruned runs ranged 2,635-2,697 ms, pruned 7.9-8.6 ms.

The unpruned cost is the per-entry anchored no-follow inspection
(`WorkspaceNoFollowItemInspector.inspect`), about 0.12 ms per entry here. The pruned scan
never enumerates the ignored trees, so its cost tracks the project's own files only. "Show
all files" keeps the unpruned scan.
