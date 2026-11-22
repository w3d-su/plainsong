# macOS AppState invalidation while typing (review finding #39)

- Date: 2026-11-20
- Measured code: `28e1b93875a9de503f044465b4f686ebb69f941c` (Debug), plus local counters
- Environment: Apple Virtual Machine 1 (`VirtualMac2,1`), virtual Apple M4 Pro, 12 cores, 16 GB RAM; macOS 26.6.2 (25G83); Xcode 26.6 (17F113)
- Fixture: synthesized ASCII Markdown (headings, prose, bold, inline code and links), 1,000 / 10,000 / 100,000 characters

## What publishes

The workspace scene supplies one facade per window ([WindowFacadeRoot.swift:48](../../App/WindowFacadeRoot.swift#L48)).
[observeCurrentDocument()](../../App/AppState+LayoutMode.swift#L103) forwards that window's
shown session publisher. [connectContainers()](../../App/AppState.swift#L187) separately forwards
its window state and the shared registry publishers.

The native editor's authorized source publication takes the current-revision path in
[AppState+EditorBinding.swift:107](../../App/AppState+EditorBinding.swift#L107), then
[AppState+DocumentEditing.swift:32](../../App/AppState+DocumentEditing.swift#L32) updates the
session with synchronous statistics disabled. [DocumentSession.swift:34](../../Packages/MarkdownCore/Sources/MarkdownCore/DocumentSession.swift#L34)
does not publish `text` or `version`, and [the edit only assigns `isDirty` if it changed](../../Packages/MarkdownCore/Sources/MarkdownCore/DocumentSession.swift#L167).
Statistics instead publish after a 300 ms typing pause if the counts changed.

The counted AppState observers were [WorkspaceWindowContent](../../App/Views/WorkspaceWindow.swift#L35),
[EditorWorkspace and DocumentEditor](../../App/Views/WorkspaceDetail.swift#L8),
[WorkspaceSidebar](../../App/Views/WorkspaceSidebar.swift#L8), and
[WorkspaceFilesSidebar](../../App/Views/WorkspaceFilesSidebar.swift#L10).
`DocumentEditor` also observes the session directly. Other observers include
[WorkspaceToolbar](../../App/Views/WorkspaceToolbar.swift#L5),
[ExportHTMLStatusBanner](../../App/Views/ExportHTMLStatusBanner.swift#L5),
and conditional chrome such as [WorkspaceInspector](../../App/Views/WorkspaceInspector.swift#L7)
and [EditorFindBar](../../App/Views/EditorFindBar.swift#L13).

## Procedure

The opt-in [hosted benchmark](../../PerformanceTests/AppStateRedrawPerformanceTests.swift) mounts
the shipping `WorkspaceWindow` and native text view in one or three AppKit windows, using
distinct sessions in the same registry. It inserts one ASCII character near the top per sample,
checks that the edit reached the session, and gives the main run loop at least 30 ms between
insertions. The first edit starts clean; the next 48 are measured separately while dirty.
Two fresh fixtures per configuration give 96 steady keys per arm and configuration.

~~~sh
make generate
TEST_RUNNER_PLAINSONG_MEASURE_APPSTATE_REDRAW=1 xcodebuild test \
  -scheme PerformanceTests -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$HOME/dd-appstate-redraw" -parallel-testing-enabled NO \
  -only-testing:PerformanceTests/AppStateRedrawPerformanceTests
~~~

The checked-in probe logs publisher counts and timings. For the local A/B, use a counter keyed
by facade identity at the top of each of the five production bodies above, snapshot the counters
at the same boundaries as publisher counts, and run fixtures in on/off/off/on order. In the off
arm only, cancel the active facade's `documentChangeCancellable` after mounting, before the
first edit. This leaves direct session observers and all other forwarding intact; it is a
diagnostic control, not a proposed change.

Synchronous insertion is wall time spent in `insertText`; main-thread CPU is the change in
`CLOCK_THREAD_CPUTIME_ID` from before insertion to after the 30 ms yield. It includes deferred
SwiftUI, AppKit and any other main-thread work in that interval. Neither metric is input-to-screen
latency, and a body evaluation does not establish a pixel redraw.

## Results

**Steady typing: 0 of 576 keys published either observable or evaluated any of the
five counted bodies with forwarding on.** With forwarding off, the corresponding
counts were also zero. The native editor still applied every edit. Across all six
configurations, pooled synchronous insertion was **1.29 / 3.09 ms** on versus
**1.29 / 3.06 ms** off (median / p95). Pooled main-thread CPU was **10.00 / 26.27 ms**
on versus **9.86 / 22.85 ms** off; per-configuration differences were mixed.

| Initial chars | Windows | Insert on (ms) | Insert off (ms) | Main CPU on (ms) | Main CPU off (ms) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 1 | 1.40 / 4.21 | 1.43 / 4.48 | 10.09 / 31.04 | 11.84 / 21.64 |
| 1,000 | 3 | 1.33 / 2.78 | 1.34 / 3.50 | 12.56 / 34.30 | 12.83 / 41.88 |
| 10,000 | 1 | 1.22 / 2.93 | 1.24 / 2.78 | 9.21 / 21.47 | 9.13 / 17.69 |
| 10,000 | 3 | 1.09 / 3.25 | 1.14 / 3.68 | 10.79 / 37.61 | 10.65 / 30.73 |
| 100,000 | 1 | 1.42 / 3.28 | 1.26 / 2.88 | 9.34 / 22.68 | 8.09 / 17.72 |
| 100,000 | 3 | 1.28 / 2.26 | 1.32 / 2.49 | 9.28 / 13.65 | 9.35 / 14.56 |

Each cell is median / nearest-rank p95 for 96 steady keys per arm.

**First clean-to-dirty key:** In all 12 fixtures per arm, the active session published
once. With forwarding on, the active facade published once and each of the five bodies
evaluated once. With forwarding off, the facade did not publish and only
`DocumentEditor` evaluated once. Pooled median insertion was **1.33 ms on / 1.20 ms off**;
median main-thread CPU in the sampling interval was **26.60 ms on / 13.67 ms off**.
That is one dirty transition per fixture, not a recurring cost or a measure of latency.

**After the burst:** Each active session published once as statistics landed. The active
facade published twice with forwarding on (each of the five bodies evaluated twice)
and once with it off (one evaluation per body, except `DocumentEditor` evaluated twice).
The control leaves the other facade publishers intact. Peer facades did not publish
and their counted bodies were not evaluated in any of the measured phases in this run.

Finding #39 describes a real broad invalidation, but not on each ordinary key in the
current edit path. These measurements do not support a refactor for steady source typing.

**Scope:** Source-only with the sidebar visible, no folder open, inspector/Find/preview closed,
and no save within the burst. These are hosted production views using the macOS 26 fixed shell,
not a standalone app `WindowGroup` or a compositor trace. Other workflows can have additional
publishers; this does not establish the full keystroke-to-screen budget.
