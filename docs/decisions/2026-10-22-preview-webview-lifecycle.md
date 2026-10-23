# The workspace creates its preview web view on first show and recovers it after a WebContent crash

`EditorWorkspace` held `@StateObject private var previewController = PreviewController()`
and wired its callbacks in `onAppear`, so every workspace window created a `WKWebView`, and
WebKit started a WebContent process and parsed the bundled page, even in the source-only
layout where the pane never appears. That process is the largest per-window memory cost
(`docs/perf-log.md` records ~250 MB of helper RSS per live web view on the 1 MiB fixture).
The workspace now owns a `LazyPreviewController` holder and asks it for the controller only
while the preview pane is in the view tree. The first request creates the controller and
wires its callbacks through a static function that receives `appState` and the scroll
coordinator, never the view, so #181's ownership rule still holds: only the view state owns
the controller. Once created, the controller lives as long as the workspace view, as before;
hiding the pane keeps the web view and its DOM, so showing it again is instant and, with the
duplicate-render key (`2026-10-22-preview-render-single-flight.md`), renders nothing.

`webViewWebContentProcessDidTerminate` only marked the controller not ready, so a crashed
or reclaimed WebContent process left a blank pane that never recovered. A live controller
(the public `PreviewController()` initializer) now reloads the bundled page and re-submits
the newest render (the pending one, else the last one sent) under a new render ID, so the
shared scroll/export barrier and checkbox provenance name what the reloaded page shows.
Three terminations in a row without a completed render stop the recovery, so a document
that crashes WebKit cannot reload in a loop; after that, each new render gets one more page
load, because the edit may have removed what crashed. Export controllers
(`makeHTMLExportController`) still fail their operation typed and never reload.

`makeHTMLExportController` looks the compiled no-HTTP rule list up in
`WKContentRuleListStore.default()`, which keeps compiled lists on disk across launches,
before compiling it. The identifier carries a version (`plainsong-export-no-http-v1`);
changing the rule requires a new identifier.

The plan's asset-handler items were re-checked against #188's reader-based handler: it no
longer uses an `OperationQueue`, reads run as async tasks that check cancellation before and
after the read, and the remaining per-request cost is one `resolvingSymlinksInPath` of the
root. Reading with `.mappedIfSafe` was rejected: an image truncated in place while mapped
raises SIGBUS in the app, for a saving on files capped at 10 MiB that WebKit copies anyway.

Alternatives: creating the controller in `onAppear`/`onChange` into `@State` (rejected:
the pane appears one frame later, and it needs the same capture discipline); releasing the
controller when the pane hides (rejected: every show would reload the page and re-render
the document, and the window's memory peak is the same); reloading on termination for every
controller (rejected: an export operation must fail rather than export a page it did not
render); an unbounded recovery loop (rejected: see above).
