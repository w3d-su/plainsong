# Syscalls and time per entry in the workspace directory scan

- Date: 2026-11-21
- Commit: `28e1b93`
- Environment: three Devin macOS VMs, each Apple M4 Pro (Virtual), 12 cores, 16 GB,
  macOS 26.6.2 (25G83), APFS; `swift build -c release` of a throwaway executable that
  links `WorkspaceKit` by path. No agent.md §12 budget applies.
- Fixture: generated in `~/bench/fx` on each machine. `depthN`: 1,000 `.md` files whose
  parent folder is N levels below the root (about 1,010-1,020 entries with the folders).
  `blog`: an Astro-style tree of 720 posts under `src/content/blog/<year>/<month>` plus
  80 component and image files (936 entries). `web`: the fixture of
  `2026-10-22-markdown-only-scan-pruning.md` (21,266 entries, most under `node_modules`).
- Procedure: `WorkspaceDirectoryScanner().snapshotCapture(root:)` (no pruning, the "Show
  all files" path) against two references in the same process: `enum`, the scanner's
  `FileManager` enumeration with the same resource keys and no inspection, and `lstat`,
  that enumeration plus one `fstatat(AT_SYMLINK_NOFOLLOW)` per entry against a cached
  parent descriptor. Syscalls: `sudo ktrace trace -S -f C4 --ndjson -c <bench> <mode>
  <root> 1`, counting the bench process's BSC syscall entries minus a no-op run of the
  same binary (204 calls). Time: one warm-up, then the median of 10 runs; cold runs follow
  `sudo purge`.
- Result: measured, no pass/fail. 28 syscalls per entry at the root, plus 10 per folder
  level above the entry: 38 one folder deep, 58 at three, 88 at six, 128 at ten. Warm scan
  time is 52-187 µs per entry against 5-8 µs for the enumeration alone. The 21,266-entry
  web fixture takes 1.71-1.96 s unpruned, against 4.2-6.6 ms with the default pruning.

## Syscalls per entry

Identical on all three machines (counts differ by at most 3 calls in a scan).

| Fixture | Entries | Scan syscalls | Per entry | Enumeration alone, per entry |
| --- | ---: | ---: | ---: | ---: |
| 1,000 files in the root | 1,000 | 28,111 | 28.1 | — |
| depth1 | 1,010 | 38,427 | 38.0 | 3.1 |
| depth3 | 1,012 | 58,702 | 58.0 | 3.1 |
| depth6 | 1,015 | 89,192 | 87.9 | 3.1 |
| depth10 | 1,019 | 129,986 | 127.6 | 3.2 |
| blog | 936 | 69,725 | 74.5 | 3.8 |
| web | 21,266 | 1,205,419 | 56.7 | 3.4 |

At depth3 a scan makes 21,215 `fstat`, 14,109 `fstatat`, 8,112 `close`, 4,075 `open`,
3,046 `mac_syscall`, 3,025 `openat`, 1,015 `dup`, and about 1,020 each of `proc_info`,
`geteuid`, `getegid` and `gettid`. The fixed part per entry comes from
`WorkspaceNoFollowItemInspector.inspect`: the root-binding proof in
`withAnchoredParent` and in each of its two `validateNamespace` calls (an `open`, `fstat`
and `close` of the root spelling each time), the `dup` and `fstat` of the retained root,
the leaf `fstatat` twice, and `startAccessingSecurityScopedResource` (the `mac_syscall`,
`proc_info` and credential calls). Each folder level above the entry adds an `openat`,
`fstat`, `fstatat` and `close` to open the chain, and an `fstat` and `fstatat` in each of
the three namespace checks: 10 calls. Nothing is shared between entries in one folder.

The executable is not sandboxed and the root URL is not security scoped. In the app,
`startAccessingSecurityScopedResource` on a bookmark-resolved root may cost more than
measured here.

## Time per entry, warm cache

Median of 10 runs, in µs per entry, for machines 1 / 2 / 3.

| Fixture | Scan | Enumeration alone | Enumeration + one `fstatat` |
| --- | --- | --- | --- |
| depth1 | 61.4 / 64.9 / 51.9 | 4.9 / 5.2 / 4.7 | 9.0 / 8.0 / 8.2 |
| depth3 | 85.8 / 83.3 / 75.3 | 6.0 / 4.5 / 4.9 | 8.5 / 7.3 / 8.0 |
| depth6 | 131.9 / 123.7 / 107.0 | 5.0 / 5.4 / 4.6 | 8.4 / 9.2 / 9.3 |
| depth10 | 180.5 / 187.3 / 176.6 | 6.8 / 5.4 / 5.7 | 9.3 / 9.7 / 14.4 |
| blog | 119.8 / 122.8 / 103.6 | 7.9 / 7.1 / 7.0 | 14.1 / 13.5 / 13.8 |
| web | 92.0 / 84.1 / 80.6 | 5.9 / 5.5 / 5.9 | 13.0 / 10.6 / 9.8 |

Whole web fixture, median ms (machines 1 / 2 / 3):

| Run | Scan, unpruned | Enumeration alone | Scan, default pruning (63 entries) |
| --- | --- | --- | --- |
| Warm | 1,957 / 1,789 / 1,715 | 125 / 116 / 126 | 6.6 / 5.4 / 4.2 |
| Cold, 3 runs after `purge` | 1,894-2,089 / 1,527-1,656 / 1,593-1,678 | 210-274 / 150-172 / 166-191 | — |

Machine 3 started with a 1-minute load average of 14.5 after boot (6 by the end), so its
numbers are the noisiest. The 2026-10-22 record measured the same web fixture at 2,658 ms (0.12 ms per entry) on an
Apple M1 Pro laptop.

## What the numbers mean

The inspection is 90-97% of the unpruned scan; enumeration and resource values are the
rest. A scan that kept one `fstatat` per entry would cost about 8-14 µs per entry here, so
the web fixture would take about 0.2-0.3 s instead of about 1.7-2.0 s.

The scan runs on the utility task when a workspace opens and again for every watcher batch
and every sidebar create, rename or delete (`scheduleWorkspaceReload`, which cancels the
previous scan). With the default pruning, a blog of about 1,000 entries scans in about
0.1 s, and `node_modules`, `dist` and similar trees are never visited. The per-entry cost
matters for "Show all files" on a web project, for deep content trees, and for watcher
bursts such as a build writing into an unpruned folder.
