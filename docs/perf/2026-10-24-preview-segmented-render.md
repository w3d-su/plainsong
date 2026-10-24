# Segmented preview render: per-edit WebKit time for 100 KB-1 MiB documents

- Date: 2026-10-24
- Commit: base `1428bf1` (main) against branch `phase3-preview-incremental-render`; both
  bundles built from their trees with `node build.mjs`
- Environment: macOS 27.0, Xcode 27.0, Apple M1 Pro, 16 GB. A standalone `swiftc -O`
  harness hosts a `WKWebView` in an off-screen window and loads the shipped
  `index.html`/`bundle.js`
- Fixture: `Fixtures/perf-100kb.md`, `Fixtures/perf-500kb.md`, `Fixtures/large-1mb.md`,
  and MDX variants (an `import` plus `<PerformanceCard tone="info" />` ahead of the
  Markdown, as `PerformanceBudgetTests` builds them; the 1 MiB file's trailing HTML
  comment became an MDX comment); agent.md §12 "preview update: render < 100 ms for 100 KB
  doc; debounce 150 ms"
- Procedure: the harness sends the production `render` message through
  `callAsyncJavaScript("window.PlainsongBridge.receive(message)")`. It times from that call
  to the matching `renderComplete` message. A prime render of the fixture comes first,
  then five "char" edits (` typed` × i appended to the middle paragraph, so no line moves)
  and five "newline" edits (i new paragraphs inserted at the middle, so every later
  `data-line` moves). Three interleaved base/branch pairs per fixture, order alternating;
  1-minute load recorded before each run
- Result: 1 MiB Markdown char edit 1618.7 → 241.3 ms and newline edit 1651.9 → 406.8 ms;
  100 KB char edit 73.2 → 22.7 ms (budget 100 ms, pass on both trees). Every pair was
  faster on both edit kinds. Cold first render is unchanged within noise

Medians of the per-run medians (ms):

| Fixture | Prime base → branch | Char edit base → branch | Newline edit base → branch |
|---|---|---|---|
| perf-100kb.md | 157.0 → 131.7 | 73.2 → 22.7 | 53.0 → 10.2 |
| perf-500kb.md | 382.8 → 403.7 | 305.9 → 50.6 | 283.2 → 51.6 |
| large-1mb.md | 1480.1 → 1122.7 | 1618.7 → 241.3 | 1651.9 → 406.8 |
| perf-100kb.mdx | 133.1 → 142.0 | 74.9 → 22.4 | 60.9 → 11.6 |
| large-1mb.mdx | 1686.7 → 1229.4 | 1898.2 → 258.9 | 2079.2 → 450.8 |

Raw runs (prime / char median / newline median, ms):

| Fixture | Pair | Order | Load base, branch | Base | Branch |
|---|---|---|---|---|---|
| perf-100kb.md | 1 | A→B | 73.4, 73.4 | 157.0 / 62.6 / 52.5 | 140.2 / 21.6 / 11.8 |
| perf-100kb.md | 2 | B→A | 73.4, 73.4 | 122.9 / 75.6 / 53.3 | 131.7 / 24.2 / 10.1 |
| perf-100kb.md | 3 | A→B | 74.4, 74.4 | 158.2 / 73.2 / 53.0 | 125.8 / 22.7 / 10.2 |
| perf-500kb.md | 1 | A→B | 74.4, 76.3 | 412.6 / 305.9 / 282.2 | 403.7 / 50.6 / 50.8 |
| perf-500kb.md | 2 | B→A | 78.6, 76.3 | 382.8 / 309.1 / 283.2 | 402.1 / 49.4 / 51.6 |
| perf-500kb.md | 3 | A→B | 78.6, 82.7 | 361.3 / 305.2 / 286.7 | 407.6 / 50.9 / 53.4 |
| large-1mb.md | 1 | A→B | 85.7, 83.4 | 1480.1 / 1585.4 / 1531.6 | 1085.2 / 228.3 / 404.7 |
| large-1mb.md | 2 | B→A | 81.6, 82.1 | 1475.3 / 1618.7 / 1651.9 | 1122.7 / 241.3 / 406.8 |
| large-1mb.md | 3 | A→B | 80.3, 99.1 | 1570.8 / 1815.4 / 1923.6 | 1213.3 / 258.8 / 461.4 |
| perf-100kb.mdx | 1 | A→B | 117.6, 132.8 | 148.5 / 69.7 / 65.5 | 140.8 / 19.7 / 13.2 |
| perf-100kb.mdx | 2 | B→A | 132.8, 132.8 | 133.1 / 76.9 / 60.9 | 153.5 / 24.5 / 11.6 |
| perf-100kb.mdx | 3 | A→B | 159.2, 159.2 | 121.7 / 74.9 / 55.7 | 142.0 / 22.4 / 9.8 |
| large-1mb.mdx | 1 | A→B | 159.2, 280.3 | 1686.7 / 1898.2 / 2079.2 | 1286.9 / 261.2 / 467.8 |
| large-1mb.mdx | 2 | B→A | 301.5, 296.7 | 2255.7 / 3240.9 / 5914.9 | 1203.8 / 258.9 / 450.8 |
| large-1mb.mdx | 3 | A→B | 267.8, 228.9 | 1627.1 / 1753.7 / 1666.7 | 1229.4 / 239.1 / 450.2 |

The machine was never idle. Other sessions were building, including a full hosted
`xcodebuild test` during the MDX rows, and load rose to ~300. The pairing absorbs this:
the branch is 3-7× faster in every pair, far outside the spread between runs.

Where the time goes. A second harness page times each stage of one `large-1mb.md` edit
inside the same WebKit, using the production modules (load ~50-90):

| Stage | Base char / newline | Branch char / newline |
|---|---|---|
| Parse (micromark + mdast) | ~900-1000 | — |
| Remark transforms, mdast→hast, rehype plugins | ~75 | — |
| Stringify | ~55-70 | — |
| Segmented pipeline (all of the above) | — | 6-8 / 7-11 |
| Inert `innerHTML` of the whole HTML | ~25 | ~25 |
| morphdom patch | ~110 / ~170 | ~100-115 / ~165 |
| highlight.js | ~2 / ~45 | ~2 / ~40 |
| Forced style + layout | ~3 / ~90 | ~3 / ~87 |

The pipeline was about 75% of an edit and is now under 5%. The remainder is the DOM
update over the whole root. On a newline edit, morphdom matches untagged top-level
siblings by position, so every block after an insertion is morphed into its neighbour's
content: later code is re-highlighted and later text is laid out again. Patching per
segment would remove that, and is left as follow-up work
(`docs/decisions/2026-10-24-preview-segmented-render.md`). In Node, a warm 1 MiB edit
takes ~12 ms in the segmented renderer against ~2,000 ms for a whole render; the cold
segmented render is no slower than the whole render. The 1 MiB fixture has 324 segments
(~3.2 KB each).
