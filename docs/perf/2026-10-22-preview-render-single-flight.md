# Single-flight preview rendering: typing-burst latency, pipeline runs and send cost

- Date: 2026-10-22
- Commit: base `6bf644e` (main) against branch `phase3-preview-render-dispatch` (render
  path as of its first commit; later commits change only docs and the inbound reader's shape)
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Apple M1 Pro, 16 GB; Debug
  `swift test` builds of PreviewKit with the committed preview bundle, one process per run
- Fixture: `Fixtures/perf-500kb.md` (typing burst), `Fixtures/large-1mb.md` (idle send);
  agent.md §12 "preview update: render < 100 ms for 100 KB doc; debounce 150 ms"
- Procedure: `PLAINSONG_RUN_PREVIEW_DISPATCH_PROBE=1 swift test --skip-build --filter
  PreviewRenderDispatchProbeTests` in two package copies (base, branch) holding only the
  probe and its two support files; 12 interleaved pairs, the order alternating per pair
  (A→B, B→A), `uptime` recorded before every run
- Result: last keystroke's text visible 1751 → 412 ms (median, 12/12 pairs faster);
  pipeline runs for 12 submissions 12 → 7; main-thread time of one idle 1 MiB render
  submission 5.38 → 0.56 ms (12/12 pairs faster). No §12 budget changes; informational.

The typing-burst probe renders the 500 KB fixture once, then submits twelve versions 150 ms
apart, as the debounced observer does while typing, and measures from the last submission to
that render's `renderComplete`. JavaScript counts the `render` messages it receives. On the
base tree every submission is sent, each runs the whole unified pipeline (~200-300 ms here),
and the last text waits for the whole backlog. With one render in flight the newest text
replaces whatever is waiting, so about every other submission is skipped and the last text
appears after at most the in-flight render plus its own.

The idle-send probe submits the 1 MiB fixture nine times with nothing in flight (both trees
send at once) and reports the median main-thread time of the submission call: on the base
tree that is `JSONEncoder` + `String(data:)` + script interpolation + `evaluateJavaScript`;
on the branch it is the Foundation argument dictionary + `callAsyncJavaScript`.

| Pair | Order | Load (1 min) before base, branch | Last text visible ms | Pipeline runs | Idle 1 MiB submit ms |
|---|---|---|---|---|---|
| 0 | A→B | 40.26, 38.56 | 1750.1 → 407.4 | 12 → 7 | 5.49 → 0.69 |
| 1 | B→A | 37.82, 36.37 | 1802.1 → 410.5 | 12 → 7 | 5.29 → 0.64 |
| 2 | A→B | 36.40, 47.38 | 1866.0 → 312.8 | 12 → 7 | 8.12 → 0.53 |
| 3 | B→A | 67.42, 66.17 | 1752.0 → 356.4 | 12 → 6 | 10.16 → 0.91 |
| 4 | A→B | 62.42, 56.25 | 1703.1 → 466.1 | 12 → 7 | 7.48 → 0.55 |
| 5 | B→A | 45.77, 49.32 | 1804.1 → 413.8 | 12 → 7 | 4.74 → 0.50 |
| 6 | A→B | 33.45, 27.81 | 1659.3 → 353.6 | 12 → 7 | 5.25 → 0.50 |
| 7 | B→A | 26.49, 21.92 | 1658.9 → 414.5 | 12 → 7 | 5.27 → 0.82 |
| 8 | A→B | 21.56, 18.55 | 1818.4 → 506.8 | 12 → 7 | 5.09 → 0.56 |
| 9 | B→A | 20.83, 22.54 | 1637.8 → 466.1 | 12 → 7 | 6.43 → 0.51 |
| 10 | A→B | 18.71, 16.76 | 1656.7 → 408.8 | 12 → 7 | 4.96 → 0.55 |
| 11 | B→A | 22.96, 16.00 | 1752.5 → 495.0 | 12 → 7 | 5.47 → 0.59 |

Medians: last text visible 1751.05 → 412.15 ms (median paired difference −1308.65 ms);
pipeline runs 12 → 7; idle submission 5.38 → 0.555 ms (median paired difference
−4.775 ms). The machine was never idle (1-minute load 16-67, other agents building), which
the pairing absorbs; the branch was faster in every pair on every metric.
