# M5 Performance Log

Record M5 performance measurements here before accepting the milestone. Each entry should identify
the commit, environment, fixture, measurement procedure, measured value, and pass/fail result. Keep
raw profiler exports or screenshots outside the repo unless they are small and intentionally useful.

## Environment

| Field | Value |
|---|---|
| Date | 2026-06-17 |
| Commit | Measured code commit `f3a9a5ac737fa844c5b6781f04993e906221277e` |
| macOS | macOS 27.0 (26A5353q) |
| Xcode | Xcode 27.0 (27A5194q) |
| Machine | Apple M1 Pro, arm64, 16 GB RAM |
| Build configuration | `Debug`; `make test` / Xcode scheme `Plainsong` |
| Notes | Evidence: Xcode result bundle `~/Library/Developer/Xcode/DerivedData/Plainsong-awqexsyzmttqfhcfdgdaneqwnuwq/Logs/Test/Test-Plainsong-2026.06.17_16-41-01-+0800.xcresult`; signpost subsystem `app.plainsong.performance`, category `M5`. |

## Summary

| Metric | Budget | Measured | Result | Procedure |
|---|---:|---:|---|---|
| Typing latency | < 16 ms | 0.520 ms max | Pass | See [Typing Latency](#typing-latency) |
| Highlight update visible range | < 50 ms | Not accepted | Blocked: visible-range plumbing gap | See [Highlight Update](#highlight-update) |
| Preview render, 100 KB document | < 100 ms after debounce | Markdown 56.787 ms median; MDX 14.459 ms median | Pass | See [Preview Render](#preview-render) |
| File open, 500 KB Markdown | < 300 ms to first paint | 38.597 ms | Pass | See [File Open](#file-open) |
| Memory with 8 warm sessions + 2 webviews | < 400 MB | 135.8 MB with 1 webview only | Informational; 2-webview gate unmet | See [Memory](#memory) |

## Typing Latency

- Fixture: `Fixtures/large-1mb.md`
- Procedure:
  1. Ran `make test`, which includes `PerformanceTests.testTypingLatencyStaysUnderFrameBudget`.
  2. The test reuses `EditorPerformanceProbe.measureTypingHotPath` against the committed
     `Fixtures/large-1mb.md` and covers Markdown plain typing, Markdown newline, Markdown
     auto-pair trigger, MDX plain typing, and MDX JSX trigger.
  3. Captured `TypingLatency` signposts in the Xcode result bundle.
- Measured value: maximum observed sample was 0.520 ms (`mdx jsx trigger`; 50 iterations).
  Other samples: Markdown plain 0.019 ms, Markdown newline 0.114 ms, Markdown pair
  0.268 ms, MDX plain 0.045 ms.
- Result: Pass.
- Notes: Existing EditorKit hot-path frame-budget package tests also passed in the
  same `make test` run.

## Highlight Update

- Fixture: `Fixtures/large-1mb.md` plus an MDX fixture with multiline JSX.
- Procedure:
  1. Open the fixture and edit a visible Markdown line.
  2. Measure visible-range highlight update time, excluding unrelated preview debounce time.
  3. Repeat after switching editor theme if M5 theme support changed highlighter behavior.
- Measured value: not accepted as a passing measurement on this branch.
- Result: Blocked.
- Notes: Choice: flag this as hidden remaining M5 work rather than adjust the agent.md
  Section 12 budget to a smaller proxy. Current parser code defers inline parsing until
  visible-range plumbing lands and skips inline parsing above 250 KB, so current measurements
  must not be treated as passing the visible-range budget. Follow-up must plumb and
  instrument visible-range highlighting before this budget can become green.

## Preview Render

- Fixture: `Fixtures/perf-100kb.md`
- Procedure:
  1. Ran `make test`, which includes `PerformanceTests.testPreviewRenderFor100KBMarkdownAndMDXStaysUnderBudget`.
  2. Warmed the preview bridge and MDX parser path, primed the live WebView with the 91,486-byte
     deterministic fixture, then ran three unmeasured settling updates to keep one-time WebKit,
     highlight, and morphdom startup work out of the settled post-debounce budget.
  3. Measured three settled large-document updates from Swift render request to JS
     `renderComplete`.
  4. Gated the median of three settled updates for `.md` and `.mdx`; raw samples are printed by the test.
  5. Captured `PreviewRenderMarkdown100KB` and `PreviewRenderMDX100KB` signposts in the Xcode result bundle.
- Measured value: Markdown median 56.787 ms, samples `[59.801, 56.787, 51.910]`.
  MDX median 14.459 ms, samples `[14.459, 14.884, 14.378]`.
- Informational cold/prime values: preview bridge warmup 623.716 ms, MDX warmup
  6.097 ms, first 100 KB Markdown prime 115.061 ms, first 100 KB MDX prime 59.611 ms.
  Unmeasured settling renders were Markdown `[96.141, 64.874, 74.060]` and MDX
  `[32.305, 15.268, 14.777]`.
- Result: Pass.
- Notes: The preview path now preserves unchanged highlighted code nodes through morphdom so
  settled large-document updates do not re-highlight unchanged fences. The budget measurement
  intentionally excludes the 150 ms debounce and records settled update render work after
  debounce. The first 100 KB Markdown prime is recorded above as informational, not claimed
  as the passing update measurement.

## File Open

- Fixture: `Fixtures/perf-500kb.md`
- Procedure:
  1. Ran `make test`, which includes `PerformanceTests.testOpening500KBMarkdownToEditorFirstPaintStaysUnderBudget`.
  2. Warmed the editor surface with a tiny document so one-time AppKit/editor framework
     initialization does not dominate the document-open budget.
  3. Loaded `Fixtures/perf-500kb.md` through `MarkdownFileStore`, created a `DocumentSession`,
     and forced an EditorKit `MarkdownSTTextView` layout/display pass as the first-paint proxy.
  4. Captured `FileOpen500KBFirstPaint` signposts in the Xcode result bundle.
- Measured value: 38.597 ms.
- Result: Pass.
- Notes: This is an automated load + editor paint proxy, not a full Finder/Open Panel UI path.

## Memory

- Scenario: 8 warm document sessions and 1 live preview webview on this branch.
- Procedure:
  1. Open a folder workspace with at least 8 Markdown/MDX files.
  2. Visit 8 files so they enter the warm-session LRU.
  3. Ensure the preview pane is visible for the current document.
  4. Record resident memory after preview settles.
- Measured value: 135.8 MB RSS with 8 warm `DocumentSession`s and 1 live `PreviewController`
  WebView. The test also printed a 100.630 ms informational preview render for that memory setup.
- Result: Informational only; the Section 12 2-webview memory gate is unmet.
- Notes: Choice: measure single-webview memory for now. Phase 1 shares one App-scoped
  `AppState` and one preview pane per editor workspace, while independent multi-window
  document state is deferred, so this branch does not provide a reliable two-live-webview
  procedure. The agent.md Section 12 two-webview memory gate remains open and must not be
  marked green from this single-webview number.

## Follow-up Actions

- [ ] [#14](https://github.com/w3d-su/plainsong/issues/14): land and instrument visible-range highlighting before claiming the
  < 50 ms highlight-update budget; current inline parsing is deferred and skipped above 250 KB.
- [ ] [#13](https://github.com/w3d-su/plainsong/issues/13): add or confirm a deterministic two-live-webview workflow or memory harness; current
  perf procedure records single-webview memory only because independent multi-window document
  state is deferred.
