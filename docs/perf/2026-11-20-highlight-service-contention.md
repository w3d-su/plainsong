# macOS Markdown highlight service under concurrent editing

- Date: 2026-11-20
- Production code measured: `28e1b93875a9de503f044465b4f686ebb69f941c` (unchanged by this benchmark)
- Environment: macOS 26.6.2 (25G83), Xcode 26.6 (17F113), Swift 6.3.3, Release; virtual Apple M4 Pro, 12 logical CPUs, 16 GiB RAM
- Fixture: source-mode Markdown, 5,120-byte and 204,728-byte line-aligned prefixes of [`perf-500kb.md`](../../Fixtures/perf-500kb.md), editing ordinary prose near the midpoint
- Result: a shared actor clearly queues simultaneous requests, but the p95 penalty over independent actors was **0.65–1.72 ms at 5 KiB** and **1.11–3.92 ms at 200 KiB** for 2–4 editors. This is a diagnostic, not a pass/fail test of the app's 50 ms after-edit highlight budget.

## How to rerun

From the repo root on macOS:

```sh
PLAINSONG_RUN_HIGHLIGHT_CONTENTION_PROBE=1 swift test --package-path Packages/EditorKit -c release -Xswiftc -enable-testing --filter MarkdownHighlightContentionProbeTests
```

The probe prints CSV rows prefixed with `highlight_probe,`. It runs 6 warm-up and 48
measured bursts per fixture/editor-count/actor configuration. In each burst it inserts
one character into each editor's own text storage, snapshots native source strings,
and submits one request per editor without waiting between submissions. It uses the
production viewport padding for a 2,200 UTF-16-unit viewport. Each configuration uses
the same production actor and styling path, with either one actor for the whole group
or one per editor. A test-only actor extension clocks the unchanged synchronous
`highlight` method from inside its isolation.

**Wait** is elapsed time from caller submission to actor entry (including the executor
hop and scheduling, not a pure mailbox counter); **compute** is wall time inside
`highlight`; **service latency** ends at actor exit and is wait plus compute per request.
**Throughput** divides request count by the summed spans from first submit to last
actor exit of each burst: it is burst service capacity, not a measured typing rate.
After each burst, the probe times the production attribute-apply helper on each
detached text view on the main actor. This apply measurement excludes SwiftUI updates,
result delivery back to the main actor, and deferred layout/display. The probe does not
time keystroke handling, the debounce, cancellation or rendering. Simultaneous
submissions deliberately stress overlap; these aren't observations of typical live
window traffic, MDX or experimental WYSIWYG.

## Measurements

Three separate test invocations. Throughput, p50 and p95 are medians of the three
per-run summaries; max is the highest sample across all runs. Timings are in ms
and shown as **p50 / p95 / max**.

| Document bytes | Editors | Actors | Req/s | Service latency | Wait | Compute | Main-actor apply |
| ---: | ---: | :--- | ---: | ---: | ---: | ---: | ---: |
| 5,120 | 1 | Shared | 1,509 | 0.614 / 0.835 / 1.925 | 0.014 / 0.033 / 0.053 | 0.600 / 0.816 / 1.901 | 0.095 / 0.141 / 0.188 |
| 5,120 | 1 | Independent | 1,458 | 0.635 / 0.791 / 1.749 | 0.015 / 0.043 / 0.137 | 0.622 / 0.772 / 1.722 | 0.104 / 0.132 / 0.179 |
| 5,120 | 2 | Shared | 1,535 | 0.898 / 1.520 / 3.667 | 0.069 / 0.794 / 1.814 | 0.594 / 0.780 / 1.852 | 0.083 / 0.140 / 0.545 |
| 5,120 | 2 | Independent | 2,882 | 0.661 / 0.872 / 1.048 | 0.019 / 0.042 / 0.165 | 0.640 / 0.828 / 0.890 | 0.082 / 0.111 / 0.145 |
| 5,120 | 4 | Shared | 1,534 | 1.636 / 2.742 / 5.449 | 1.053 / 2.064 / 4.038 | 0.641 / 0.761 / 1.600 | 0.082 / 0.130 / 0.332 |
| 5,120 | 4 | Independent | 4,187 | 0.809 / 1.025 / 3.150 | 0.030 / 0.069 / 0.109 | 0.769 / 0.981 / 3.103 | 0.074 / 0.107 / 0.147 |
| 5,120 | 8 | Shared | 1,604 | 2.809 / 5.129 / 6.793 | 2.228 / 4.525 / 6.018 | 0.594 / 0.729 / 1.587 | 0.074 / 0.124 / 0.405 |
| 5,120 | 8 | Independent | 6,499 | 1.014 / 1.376 / 4.086 | 0.053 / 0.151 / 1.120 | 0.939 / 1.275 / 3.875 | 0.070 / 0.101 / 0.178 |
| 204,728 | 1 | Shared | 710 | 1.385 / 1.615 / 2.057 | 0.016 / 0.030 / 0.097 | 1.377 / 1.585 / 2.035 | 0.171 / 0.219 / 0.408 |
| 204,728 | 1 | Independent | 732 | 1.287 / 1.679 / 3.154 | 0.015 / 0.043 / 0.906 | 1.271 / 1.658 / 3.098 | 0.166 / 0.224 / 0.797 |
| 204,728 | 2 | Shared | 716 | 1.719 / 3.168 / 5.970 | 0.062 / 1.651 / 4.321 | 1.322 / 1.641 / 4.280 | 0.164 / 0.230 / 0.374 |
| 204,728 | 2 | Independent | 1,189 | 1.443 / 2.057 / 3.272 | 0.021 / 0.055 / 1.441 | 1.426 / 2.018 / 3.230 | 0.161 / 0.221 / 0.517 |
| 204,728 | 4 | Shared | 718 | 3.469 / 5.998 / 8.520 | 1.886 / 4.537 / 5.433 | 1.375 / 1.649 / 4.116 | 0.163 / 0.249 / 0.494 |
| 204,728 | 4 | Independent | 2,272 | 1.641 / 2.082 / 2.699 | 0.030 / 0.069 / 0.240 | 1.611 / 2.026 / 2.579 | 0.151 / 0.201 / 0.555 |
| 204,728 | 8 | Shared | 733 | 6.109 / 11.785 / 26.462 | 4.768 / 10.199 / 24.633 | 1.247 / 1.752 / 8.029 | 0.144 / 0.205 / 0.700 |
| 204,728 | 8 | Independent | 3,390 | 2.029 / 2.587 / 6.160 | 0.058 / 0.141 / 0.924 | 1.961 / 2.464 / 6.133 | 0.135 / 0.183 / 1.236 |

At four 200 KiB editors, the shared service's p95 latency was 5.50–6.25 ms across
runs versus 1.97–2.14 ms independently. Its wait p95 was 4.54 ms versus 0.07 ms
in the aggregate, even though its compute p95 was lower (1.65 vs 2.03 ms).
The one-editor control is comparable in both modes. This points to queueing,
not slower per-request compute, as the source of the extra latency. The
main-actor attribute apply was under 0.25 ms at p95 for 2–4 editors in both modes.
At eight 200 KiB editors, the shared actor reached 11.79 ms p95 and 26.46 ms max
excluding debounce, main-actor delivery and paint.

**Recommendation:** keep the shared actor for ordinary 2–4-window source-mode work
based on these numbers. Independent actors increase burst capacity, but save only
about 1–4 ms at p95 under deliberately overlapping requests at those editor counts.
Revisit if a live trace shows frequent multi-window overlap or long tail waits
under heavier documents or presentation modes.

## What is serialized

- [`PlainsongApp.swift:44`](../../App/PlainsongApp.swift#L44) creates workspace windows;
  [`WorkspaceDetail.swift:122`](../../App/Views/WorkspaceDetail.swift#L122) instantiates
  the Markdown editor. Each [`MarkdownEditorView`](../../Packages/EditorKit/Sources/EditorKit/MarkdownEditorView.swift#L20)
  has its own scheduler but uses the same static highlight actor. Edits restart the
  scheduler, which [debounces for 20 ms](../../Packages/EditorKit/Sources/EditorKit/MarkdownEditorView.swift#L210)
  before calling the actor. A new edit can cancel a stale request, but each
  [scheduler waits for its in-flight call to return](../../Packages/MarkdownCore/Sources/MarkdownCore/HighlightScheduler.swift#L76)
  before issuing another.
- [`MarkdownHighlightService.highlight`](../../Packages/EditorKit/Sources/EditorKit/MarkdownSyntaxHighlighter.swift#L17)
  is synchronous and actor-isolated: theme/font resolution, viewport expansion,
  tokenization and attributed-string construction do not interleave across windows.
  The actor reuses a mutable parser and caches one custom-theme resolution; the
  [parser](../../Packages/SyntaxKit/Sources/SyntaxKit/MarkdownSyntaxParser.swift#L28)
  holds Markdown block/inline parsers and lazy TSX parser/query and YAML parser
  caches, not per-document trees. Source mode scans line/fence context and parses
  the [expanded fragment](../../Packages/SyntaxKit/Sources/SyntaxKit/MarkdownSyntaxParser.swift#L57),
  not the entire 200 KiB document.
- After the await, the [editor checks the request revision](../../Packages/EditorKit/Sources/EditorKit/MarkdownEditorView.swift#L254)
  and publishes styling on the main actor. The
  [native update](../../Packages/EditorKit/Sources/EditorKit/MarkdownTextView.swift#L310)
  applies matching style runs in place if the editor is eligible. That work is
  outside the highlight actor.
