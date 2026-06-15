# M5 Performance Log

Record M5 performance measurements here before accepting the milestone. Each entry should identify
the commit, environment, fixture, measurement procedure, measured value, and pass/fail result. Keep
raw profiler exports or screenshots outside the repo unless they are small and intentionally useful.

## Environment

| Field | Value |
|---|---|
| Date | TODO |
| Commit | TODO |
| macOS | TODO |
| Xcode | TODO |
| Machine | TODO |
| Build configuration | TODO |
| Notes | TODO |

## Summary

| Metric | Budget | Measured | Result | Procedure |
|---|---:|---:|---|---|
| Typing latency | < 16 ms | TODO | TODO | See [Typing Latency](#typing-latency) |
| Highlight update visible range | < 50 ms | TODO | Blocked: visible-range plumbing gap | See [Highlight Update](#highlight-update) |
| Preview render, 100 KB document | < 100 ms after debounce | TODO | TODO | See [Preview Render](#preview-render) |
| File open, 500 KB Markdown | < 300 ms to first paint | TODO | TODO | See [File Open](#file-open) |
| Memory with 8 warm sessions + current single webview | Informational; agent.md Section 12 budget remains < 400 MB with 2 webviews | TODO | TODO | See [Memory](#memory) |

## Typing Latency

- Fixture: `Fixtures/large-1mb.md`
- Procedure:
  1. Build a release or representative development build.
  2. Open the fixture in Plainsong.
  3. Type at the top, middle, and end of the document while the preview pane is both visible and hidden.
  4. Use the existing hot-path tests, Instruments, or signposts if available to capture keystroke handling time.
- Measured value: TODO
- Result: TODO
- Notes: TODO

## Highlight Update

- Fixture: `Fixtures/large-1mb.md` plus an MDX fixture with multiline JSX.
- Procedure:
  1. Open the fixture and edit a visible Markdown line.
  2. Measure visible-range highlight update time, excluding unrelated preview debounce time.
  3. Repeat after switching editor theme if M5 theme support changed highlighter behavior.
- Measured value: TODO
- Result: TODO
- Notes: Choice: flag this as hidden remaining M5 work rather than adjust the agent.md
  Section 12 budget to a smaller proxy. Current parser code defers inline parsing until
  visible-range plumbing lands and skips inline parsing above 250 KB, so current measurements
  must not be treated as passing the visible-range budget.

## Preview Render

- Fixture: `Fixtures/perf-100kb.md`
- Procedure:
  1. Open the fixture with preview visible.
  2. Edit text that invalidates preview rendering.
  3. Measure render work after the configured debounce, from Swift render request to JS render completion.
  4. Repeat for `.md` and `.mdx` if MDX pipeline work changed render cost materially.
- Measured value: TODO
- Result: TODO
- Notes: TODO

## File Open

- Fixture: `Fixtures/perf-500kb.md`
- Procedure:
  1. Launch Plainsong with no warm document state.
  2. Open the fixture from a folder workspace or single-file flow.
  3. Measure from selection/open action to first editor paint.
- Measured value: TODO
- Result: TODO
- Notes: TODO

## Memory

- Scenario: 8 warm document sessions and 1 live preview webview on this branch.
- Procedure:
  1. Open a folder workspace with at least 8 Markdown/MDX files.
  2. Visit 8 files so they enter the warm-session LRU.
  3. Ensure the preview pane is visible for the current document.
  4. Record resident memory after preview settles.
- Measured value: TODO
- Result: TODO
- Notes: Choice: measure single-webview memory for now. Phase 1 shares one App-scoped
  `AppState` and one preview pane per editor workspace, while independent multi-window
  document state is deferred, so this branch does not provide a reliable two-live-webview
  procedure. The agent.md Section 12 two-webview memory gate remains open.

## Follow-up Actions

- [ ] M5 hidden work: land and instrument visible-range highlighting before claiming the
  < 50 ms highlight-update budget; current inline parsing is deferred and skipped above 250 KB.
- [ ] Add or confirm a deterministic two-live-webview workflow or memory harness; current
  perf procedure records single-webview memory only because independent multi-window document
  state is deferred.
