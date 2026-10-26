# WebKit helpers a source-only workspace no longer starts

- Date: 2026-10-22
- Commit: `phase3-preview-webview-lifecycle` (on `phase3-preview-render-dispatch`)
- Environment: macOS 27.0 (26A428), Xcode 27.0 (27A5194q), Apple M1 Pro 16 GB; Debug
  `swift test` of PreviewKit with the committed preview bundle; 1-minute load 16-70, a
  hosted `xcodebuild test` running at the same time
- Fixture: none (idle page); agent.md §12 memory budget covers host RSS only, so WebKit
  helpers are diagnostic
- Procedure: `PLAINSONG_RUN_PREVIEW_FOOTPRINT_PROBE=1 swift test --skip-build --filter
  PreviewWebViewFootprintProbeTests`, five runs, one fresh test process each. The probe
  lists `com.apple.WebKit.*` processes with `ps` before creating a live `PreviewController`,
  waits for the bundle's `ready` plus 2 s, and sums the RSS of the helpers that appeared.
- Result: an idle live preview started 3 helpers (WebContent, GPU, Networking) totalling
  74.7 MB RSS (median; runs 74.7, 50.4, 73.6, 105.1, 77.6 MB). The 105.1 MB run also
  counted an `EnhancedSecurity` WebContent process started by the concurrent hosted run.

Before this change every workspace window paid that cost at mount, whatever its layout. A
source-only window now starts none of them until the preview is first shown. GPU and
Networking helpers are shared per app, so a second source-only window saved only its own
WebContent process. A rendered document costs much more: `docs/perf-log.md` records
~250 MB of helper RSS per live web view with the 1 MiB fixture.
