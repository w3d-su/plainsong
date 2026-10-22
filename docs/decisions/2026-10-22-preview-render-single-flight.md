# The preview keeps one render in flight and sends `render` as a `callAsyncJavaScript` argument

`PreviewController.submitRender` sent every render as soon as the bridge was ready.
JavaScript only notices that a render is stale after an `await`, and unified's
`process` does its parsing before its first await, so every render already queued in
WebKit ran the whole pipeline. When a render takes longer than the 150 ms debounce (a
500 KB post takes 200-300 ms), typing built a backlog, and the last keystroke's text
appeared only after every queued render finished. Each send also JSON-encoded the whole
document, copied it into a `String`, interpolated it into a script, and had WebKit parse
that script; for the 1 MiB fixture that was ~7 ms of main-thread work per render.

Now one render is in JavaScript at a time. A new request replaces the pending one, and
the pending one is sent when the in-flight render posts `renderComplete`, including a
superseded one whose completion is otherwise ignored. A 2 s watchdog frees the slot when
JavaScript never answers: the md path rethrows pipeline errors without `renderComplete`,
and a render dropped as stale posts nothing. A render JavaScript never received
(`callAsyncJavaScript` failed) frees the slot at once. Theme and remote-image policy are
read when a pending render is sent, so a later `setTheme` is not undone by an older payload.

Checkbox provenance (`checkboxRenderID`/`checkboxVersion`/`checkboxSession`, the iOS
identity) and the shared scroll/export barrier still name the newest *submitted* render.
A pending render that a newer one replaces is never sent, so no DOM can carry its ID, and
the newest submission is always sent eventually; a click on the in-flight DOM while a newer
render waits is rejected, as it was while a newer render was in flight before.

`render` goes through `callAsyncJavaScript("window.PlainsongBridge.receive(message)")`
with the message as a Foundation dictionary argument. JavaScript receives the same object
`JSONEncoder` produced (a nil `baseDir` stays absent, Booleans stay Booleans; a hosted test
compares the two), so `PROTOCOL_VERSION` does not change. Other Swift-to-JavaScript messages
are small and keep the JSON script path.

`PreviewController.render(_:for:)` drops a session render whose (session identity, version,
file, presented document, workspace asset root, theme, remote-image policy) equals the last
submission. Showing the pane or switching documents renders at once, and the restarted
`observe(_:)` then yielded the same text again 150 ms later, a second full pipeline run that
also held back pending navigation behind a new render ID. A session-less render (export,
tests, iOS) clears the record, and so do WebContent termination and a failed delivery.

Smaller changes in the same lane: `assetContext` (two `resolvingSymlinksInPath` calls per
render) is cached per (file URL, workspace root), while the asset handler still checks
containment on every request; editor viewport scrolls keep one `scrollToLine` in flight with
only the newest line waiting and carry no completion or receipt, while document navigation
keeps its render barrier and receipt and discards waiting viewport lines; the scroll-owner
token is a deadline timestamp instead of a decay `Task` per scroll event; inbound bridge
bodies are read field by field (the Codable decoder's acceptance rules, test-checked)
instead of `JSONSerialization` plus a fresh `JSONDecoder` per scroll frame; an unchanged
`setTheme`/`setAllowsRemoteImages` sends nothing. Measurements:
`docs/perf/2026-10-22-preview-render-single-flight.md`.

Alternatives: dropping stale renders in JavaScript before the pipeline starts (rejected:
the stale check can only run when the queued message is dequeued, which is after the
previous render's synchronous pipeline work, and the JavaScript bundle is lane 1's); a
`textChanges(includeCurrent: false)` observer instead of the duplicate key (rejected: a text
change between the pane's immediate render and the observer's subscription would be lost,
and a new session object with an unchanged editor identity relies on that first yield);
cancelling the in-flight render (rejected: JavaScript cannot interrupt synchronous pipeline
work); a watchdog scaled to document size (rejected: a slow render that outlives 2 s only
lets one newer render start, and the stale check drops the older result); moving checkbox
provenance to the sent render (rejected: it changes the documented "latest submitted"
rule and the iOS identity contract for no safety gain); a JSON string argument to
`callAsyncJavaScript` (rejected: JavaScript would still parse the whole document).
