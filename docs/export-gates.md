# Phase 3 Export (HTML / PDF / Print) — Gate Specification

> **Status: E0 mechanism gate closed as GO (paginated); E1–E9 remain open.** Precedent:
> PR #45 and PR #95. Every E0–E9 checkbox may be checked only with named test evidence
> or an owner-recorded result in the same commit. Decisions D3–D5 require explicit owner
> sign-off before any implementation PR starts.

Created 2026-07-29 as a Phase 3 export candidate from `agent.md` §14. See `agent.md`
§7 (preview and bridge), §11 (themes), §17.5 (bridge mirroring), the PR #24/#27
asset-security Decision Log entry, and the PR #84/#85 retained-authority decisions.

## 1. Outcome

Ship a layout-independent export path for the current Markdown or MDX document:

- **Export as HTML…** writes one self-contained, static HTML file representing the
  completed, sanitized preview.
- **Export as PDF…** silently generates PDF bytes from the same completed render, then
  writes them to a user-selected destination. It does not show a print panel.
- **Print…** presents the standard macOS print panel for the same completed render.
- Source-only, source+preview, and Experimental WYSIWYG produce the same exported
  document. Export never depends on whether the visible preview is currently mounted or
  laid out.
- Export never changes source text, dirty state, the saved baseline, document identity,
  the visible preview's scroll position, or workspace/session authority.

## 2. Code-Verified Baseline

These statements describe the current `main` implementation. They are not export
capabilities:

| Observation | Evidence |
|---|---|
| `PreviewController` exposes its `webView` plus observe/render, scroll, theme, remote-image preference, and workspace-asset-root operations. There is no HTML, PDF, Print, or save-panel export path today. | `Packages/PreviewKit/Sources/PreviewKit/PreviewController.swift` |
| A render-completion callback exists only as an internal observer. On a successful render, JS posts `renderComplete` after DOM patching, highlight.js, and awaited Mermaid rendering; Swift stale-drops older render IDs. The MDX-error branch also posts `renderComplete` while retaining stale last-good DOM, so this message alone is **not** a success or export-readiness signal. | `PreviewController.swift`; `preview-src/src/index.ts` |
| The bridge is protocol **v5** with exactly **8** ordered messages: `ready`, `render`, `renderComplete`, `scrollToLine`, `previewScrolled`, `linkClicked`, `checkboxToggled`, and `setTheme`. | `BridgeMessage.swift`; `preview-src/src/bridge.ts` |
| File menu commands live in `App/PlainsongCommands.swift`: New/Open/Open Recent use `CommandGroup(replacing: .newItem)` and Save uses `CommandGroup(replacing: .saveItem)`. There is no export or Print command there today. | `App/PlainsongCommands.swift` |
| Preview-relative images are rewritten to `asset://`. Under the PR #24/#27 policy, resolution must stay inside the allowed root (including symlink containment), and only PNG, JPEG, GIF, or WebP assets of at most **10 MiB each** are served. SVG and other active/ambiguous formats are rejected. | `agent.md` §7.1 and Decision Log; `AssetURLSchemeHandler.swift`; `AssetURLResolver.swift` |

The baseline does **not** establish that a hidden or zero-sized WebView can lay out a
complete document, that `renderComplete` is sufficient for PDF capture, or that PDF
generation returns usable bytes. E0 exists to answer those questions before production
work.

## 3. Decisions Fixed by This Specification

| ID | Fixed choice | Owner sign-off before implementation |
|---|---|---|
| **D1** | Dedicated offscreen `PreviewController`; await its matching `renderComplete`; never export from the visible WebView. | No separate product sign-off. E0 evidence is still blocking. |
| **D2** | Typed protocol-v6 export request/result; no undocumented `evaluateJavaScript` read of `outerHTML`. | No separate product sign-off; this follows `agent.md` §17.5. |
| **D3** | One self-contained HTML file with bounded raster `data:` URIs and deterministic omission placeholders. | **Required.** |
| **D4** | Both silent **Export as PDF…** and panel-based **Print…**, using different WebKit APIs. | **Required.** |
| **D5** | One-shot `NSSavePanel` destination, deliberately outside the retained workspace-file write path. | **Required.** |

Explicit approval of D3–D5 must be recorded by the owner in this PR before PR B begins.
Silence, implementation activity, or a green CI run is not owner sign-off.

### D1 — Export source: dedicated offscreen preview

**Choice:** Create a dedicated offscreen `PreviewController` for each export operation.
Capture the exact current source, file kind, base directory / workspace asset root, and
resolved built-in preview theme at invocation. Before its first render, force that
controller's remote-image setting to `false`, regardless of the user's live-preview
preference; render the snapshot; then await `renderComplete` for that controller's exact
`renderID`. `renderComplete` is necessary but not sufficient: before HTML, PDF, or Print
may capture, the protocol-v6 shared export-ready barrier in D2 must also report correlated
success for the current DOM. The export controller must never read from, scroll, resize,
re-theme, or otherwise disturb the visible preview WebView.

The sole pre-protocol exception is E0's non-user-facing diagnostic PDF call after exact
`renderComplete`. It may prove only that WebKit can return full-content bytes from the
offscreen geometry; it is not a production export path, cannot be reachable from App or
write a destination, and closes no readiness/resource gate. Once protocol v6 exists,
every production HTML/PDF/Print capture requires the shared barrier.

**Rationale:**

- Source-only and Experimental WYSIWYG may leave the on-screen preview unmounted or
  unlaid-out.
- A visible source+preview WebView may be between renders or carry user-owned scroll
  state. Reusing it couples export correctness to transient UI state.
- An isolated controller gives HTML, PDF, and Print one deterministic render source and
  lets cancellation discard the whole operation without restoring UI state.

**Rejected:** Exporting the live on-screen WebView. It cannot satisfy layout-mode parity
and creates an avoidable scroll/appearance race.

**Gate consequence:** If E0 cannot prove an offscreen completed render plus usable PDF
bytes, implementation stops. Do not fall back to the visible WebView; amend this spec and
the Decision Log first.

### D2 — HTML acquisition: bridge protocol v6

**Choice:** Add one typed export operation to the bridge as a correlated, multi-round
request/result pair:

- Swift → JS: `exportHTML` with an export request ID, the completed `renderID`, and a
  typed discovery or finalization phase.
- JS → Swift: `exportHTMLResult` with the same IDs and one typed state:
  `resourcesNeeded`, `ready(html)`, or `failed`.

This makes protocol v6 contain 10 ordered message names. The implementation commit must
change `BridgeMessage.swift` and `preview-src/src/bridge.ts` together, bump
`PROTOCOL_VERSION` to 6, regenerate the committed preview bundle with
`make preview-bundle`, and update protocol tests in that same commit, as required by
`agent.md` §17.5.

During discovery, JS reports the exact `asset://` references and manifest-known bundled
font resources needed by the completed DOM. PreviewKit—not JS—resolves local images
through the existing containment/type/size policy, reads bundled fonts, and sends a
typed data-URI or omission outcome back in the finalization phase. The same two message
names carry every round; no extra unversioned callback is allowed.

`ready(html)` is the shared export-ready barrier for **all three** output paths. It may be
sent only when:

1. the requested `renderID` is still current and represents a successful render (not
   MDX stale/error state);
2. D3 allow/omit outcomes have been applied to both the live offscreen export DOM and
   the static-document clone;
3. Mermaid has completed, `document.fonts.ready` has settled, and every retained image
   has decoded or been replaced by its omission placeholder; and
4. the complete static document passes D3's size, CSP, and URL-sink checks.

PDF and Print capture the finalized live offscreen DOM only after this same barrier.
The returned HTML is a deliberately constructed static document, not an incidental DOM
dump. JS receives no filesystem authority and performs no export-time network fetch.
E0's earlier diagnostic PDF-byte probe is the narrow feasibility exception defined in
D1; it cannot be promoted or connected to a product surface without this barrier.

**Rationale:** Export is a versioned cross-layer capability with correlation, failure,
and stale-result semantics. Keeping it in the typed protocol makes Swift/TypeScript drift
testable and reviewable.

**Rejected:** Calling `evaluateJavaScript` to read
`document.documentElement.outerHTML`. That bypasses the documented protocol, has no typed
failure/staleness contract, and would serialize live bridge/runtime state rather than the
v1 static-export contract.

### D3 — HTML asset and styling policy

**Choice:** HTML export is one portable, offline file. It creates no sibling asset
directory and depends on no relative file path or remote request.

#### Images

| Input | Exported result |
|---|---|
| Contained local PNG/JPEG/GIF/WebP, actual bytes ≤ 10 MiB | Inline as a MIME-correct `data:` URI after the existing `asset://` containment/type/size policy accepts and reads it. |
| Authored `data:` image | Keep only after decoding proves an allowlisted raster MIME and decoded payload ≤ 10 MiB; serialize a normalized `data:` URI. |
| SVG, unsupported format, oversize, missing/unreadable file, path/symlink escape, or remote `http(s)` image (even when live-preview remote images are enabled) | Remove every network/path-bearing `src` and replace the image with an inert, escaped, visible and accessible alt-text placeholder. Empty alt uses the deterministic label `Image unavailable in export`. Export continues; it never silently embeds or links the rejected image. |

The 10 MiB limit is per image and is the existing PR #24/#27 boundary. Self-contained
export adds two aggregate v1 limits:

- at most **32 MiB** of distinct decoded raster payload may be retained for one
  operation; repeated references to the same accepted asset count once here; and
- the complete serialized HTML document is at most **64 MiB UTF-8**, including every
  repeated base64 occurrence, embedded CSS, and fonts.

Resources are visited in stable document order. An otherwise eligible image whose
occurrence would cross either limit becomes the same inert placeholder with the reason
`Export image size limit`; later images remain independently eligible if they fit.
If source/markup/styles/fonts without optional images already exceed 64 MiB, the whole
export fails before any destination write. A future change to any per-image or aggregate
limit needs measured evidence, owner sign-off, and a Decision Log entry.

#### Rendered styling

- Embed the resolved current built-in preview-theme CSS, MDX-placeholder styles, and
  print rules in the HTML. `system` is resolved to the current appearance at export time
  so the file does not change theme later.
- Serialize post-highlight highlight.js markup and embed its bundled theme CSS. No
  highlight.js runtime is exported.
- Serialize KaTeX markup, embed its bundled CSS, and inline only the app-bundled,
  manifest-known KaTeX fonts as font `data:` resources. User-controlled font paths are
  not accepted.
- Serialize SVG generated by bundled KaTeX or Mermaid after the export-ready barrier,
  with resolved theme styling. These exceptions are only for SVG generated by bundled
  renderers from sanitized preview content; user-authored SVG remains rejected.
- Remove bridge hooks, runtime scripts, inline event handlers, and checkbox writeback.
  Task checkboxes remain visible but inert.
- Emit a restrictive export CSP:
  `default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:;
  font-src data:; connect-src 'none'; media-src 'none'; object-src 'none';
  frame-src 'none'; base-uri 'none'; form-action 'none'`.
- Revalidate every URL-bearing HTML/SVG attribute and CSS `url(...)`. Images may use only
  accepted `data:image/...`; fonts only manifest-known `data:font/...`; generated SVG
  may use same-document `#fragment` references; ordinary links may retain only
  `http:`, `https:`, `mailto:`, or same-document fragments. Remove relative, `file:`,
  `asset:`, `javascript:`, other `data:`, external SVG, form, frame, object, and media
  targets.

**Rationale:** One file is portable, works offline, requires exactly one user-authorized
write, and cannot retain `asset://`, workspace paths, or remote dependencies.

**Rejected:**

- A sibling assets folder: it expands one user choice into multi-file namespace writes,
  partial-failure cleanup, collision rules, and relocation semantics.
- Relative paths: they leak workspace coupling and usually break when the HTML file
  moves.
- Fetching remote images: it makes export network-dependent and bypasses the local
  raster/containment policy.

**Owner sign-off:** Required because portability, output size, deterministic omission,
and static-theme fidelity are user-visible product choices.

### D4 — PDF and Print are separate paths

**Choice:** Ship both workflows from the same completed offscreen render:

- **Export as PDF…** uses the `WKWebView.createPDF(configuration:)` API family (the
  current Swift concurrency overlay is `pdf(configuration:)`) to obtain PDF `Data`.
  After a one-shot `NSSavePanel` selection, Plainsong writes those bytes without showing
  the print panel.
- **Print…** obtains `printOperation(with:)` from the offscreen WebView and runs the
  standard macOS print panel. It does not preflight through `NSSavePanel`; system print
  destinations, including the panel's PDF actions, remain owned by AppKit.

Both paths must wait for the exact render and export resources (images, fonts, KaTeX,
highlighting, and Mermaid) to settle through D2's shared barrier. D3 allow/omit,
aggregate-size, CSP, and URL-sink decisions apply to the offscreen DOM before either API
runs, so PDF/Print cannot include a remote or rejected image. Neither may use the visible
preview.

**PDF page model:** v1 Export as PDF targets one continuous full-document page. After the
offscreen WebView receives a nonzero export viewport and completes layout,
`WKPDFConfiguration.rect` covers the exact full scrollable content bounds from the first
through last sentinel. Print remains paper-paginated by `NSPrintInfo` and the standard
panel. The two paths must have equivalent content/theme/assets, not identical page
breaks.

A continuous page is **not assumed reachable for every document**. PDF's default user
space caps one page at **14,400 units (200 inches) per side**. A long-form post — the
primary Plainsong use case — reaches that laid-out height well before
`Fixtures/perf-100kb.md` does, so this is a mainline case, not an edge case. E0 must
measure a fixture whose laid-out content height **exceeds 14,400 pt** and record what
WebKit actually does at and beyond that bound: clip, scale, fail, or emit an invalid page
box.

**Conditional fallback, fixed here so an E0 NO-GO does not block PR G on a fresh
decision:** if the continuous page proves unreachable or unusable past that bound, Export
as PDF paginates at a fixed page height at or below the platform maximum, with no content
duplicated or dropped across breaks. Every other D4 term is unchanged: it still uses
`createPDF`, still shows no print panel, and still captures the same barrier-completed
offscreen render, so the signed-off two-surface product contract is preserved. Do not
silently switch silent export to `printOperation`, and do not quietly narrow the export to
whatever happens to fit. If neither the continuous page nor fixed-height pagination is
achievable, stop and amend D4 before implementation.

**Rationale:** `createPDF` is the deterministic byte-producing API for an app-owned PDF
artifact; `printOperation(with:)` is the native user-controlled printing workflow. One
cannot substitute for the other's product contract.

**Rejected:** Using `printOperation(with:)` for silent PDF export (it makes an app-owned
artifact depend on panel interaction), and shipping only PDF export with no Print path
(it omits the standard macOS workflow).

**Owner sign-off:** Required because this fixes two File-menu surfaces and their distinct
interaction models.

### D5 — One-shot sandbox write path

**Choice:** HTML and PDF exports write exactly one derived artifact to the URL returned
by the current operation's `NSSavePanel`. The grant is one-shot: do not bookmark, cache,
or reuse it for a later export. Print remains owned by `NSPrintOperation` and does not use
this path.

This is a deliberate exception to the retained-authority anchored write path established
by PR #84/#85:

- Workspace Save, Save Copy, rename/move, and recovery mutate or relocate canonical
  editor-owned files whose identity and recovery state must survive asynchronous
  lifecycle changes.
- Export creates a new, derived artifact at a destination the user explicitly authorizes
  for that one operation. It is not a `DocumentSession`, workspace item, saved baseline,
  or recovery authority, so retaining it would expand authority rather than preserve
  correctness.

The one-shot operation may use a sibling staging name only when the Powerbox grant or a
coordinated safe-save mechanism authorizes the selected parent and staging operation. A
leaf grant is never treated as blanket parent authority; inability to establish the
required scope fails before writing, with no direct-write fallback.

Within that grant, the operation may hold ephemeral no-follow parent/item descriptors
and create one OS-random exclusive staging file solely to write and flush the bytes.
Publication follows the existing safe-write primitives without routing the artifact
through retained workspace mutation authority:

- a destination proven missing publishes with `renameatx_np(..., RENAME_EXCL)`;
- an owner-confirmed existing regular file publishes only with
  `renameatx_np(..., RENAME_SWAP)`, leaving the displaced destination identity at the
  staging name; and
- after publication, postflight must prove the selected leaf contains the writer-owned
  bytes, the staging leaf contains the exact panel-approved displaced identity, and the
  held namespace is unchanged before cleanup and success.

If overwrite postflight finds a mismatch, a reverse swap is allowed only after proving
both names still hold the exact expected identities. Otherwise both identities remain
preserved, the result is reported as committed-but-indeterminate with exact
selected/staging paths, and no automatic retry or cleanup follows. Unsupported exchange,
exclusive-create, scope, durability, or cleanup semantics fail closed; ordinary
rename-overwrite, truncating direct write, and destructive fallback are forbidden.
Success requires the staging name to be proven absent. Descriptors and authority are
released when the operation ends and are never bookmarked or journaled. These
name-based operations are not described as identity-atomic.

The exception is narrow. The export path must still refuse to:

1. Write without a fresh successful panel result, after cancellation, when the exact
   operation-scoped leaf/parent/staging authority cannot be established, or by falling
   back to a direct write or another directory.
2. Follow a symlink or replace a directory, device, or other non-regular destination. A
   new leaf must use exclusive publication; a confirmed overwrite may swap only with the
   exact regular-file identity approved by the panel. Every observed identity/type change
   before publish fails closed, and every unexpected post-swap identity is preserved.
3. Overwrite any identity returned by the existing authoritative App ownership inventory
   used by Save Copy and workspace mutations—not a new export-specific URL list. That
   inventory includes current, warm/cached, retired, quarantined/detached, editor-bound,
   context-only, recovery, and indeterminate aliases. Comparison includes hard links and
   the filesystem's case/canonical aliases, not only URL-string equality.
4. Create a delivered sibling asset/font file, intermediate directory, persistent
   recovery journal, or second output. The bounded operation-only staging file above is
   the sole exception and cannot survive a reported success; it may remain only after a
   truthfully reported indeterminate failure to avoid destroying an identity.
5. Rekey a session, mark source saved/clean, change recents, adopt the export as the
   current document, or enter the workspace mutation/recovery journal.
6. Retry silently at an old/stale URL or treat a partial/uncertain write as success.

**Rejected:** Routing exports through the retained workspace mutation API. That would
misclassify a derived one-shot artifact as canonical workspace state and retain authority
the user did not ask Plainsong to keep. A broad uncoordinated URL write is also rejected;
the one-shot path remains exact-leaf, fail-closed, and side-effect-free on the document.

**Owner sign-off:** Required because this is an explicit, narrowly bounded exception to
the repository's strongest filesystem-authority policy.

## 4. Layering

```text
App
  File commands, exact document snapshot, NSSavePanel / NSPrintOperation orchestration,
  one-shot write result and user-visible errors
    PreviewKit                          WorkspaceKit
      offscreen PreviewController         one-shot non-retained artifact writer reusing
      lifecycle, render/result fencing,   the existing anchored no-follow descriptor and
      asset:// policy, WKWebView          RENAME_EXCL / RENAME_SWAP publication
      PDF and print APIs                  primitives
        preview-src
          completed render, protocol-v6 static HTML serializer, asset/style finalization
```

- App composes the operation; it does not construct HTML or read live DOM.
- PreviewKit owns WebKit and the custom asset scheme. It does not import App or
  WorkspaceKit.
- PR E's one-shot artifact writer lives in **WorkspaceKit**, beside — not inside — the
  retained mutation path. It exposes a one-shot API that consumes the panel-granted URL
  for exactly one operation, holds no bookmark, journal, session, or recovery authority,
  and returns a typed committed / not-committed / indeterminate outcome. App calls it
  directly; PreviewKit never does, and this adds no PreviewKit → WorkspaceKit edge.
- **Rejected:** implementing D5's publication primitives in App or PreviewKit.
  WorkspaceKit already owns the only audited `openat(O_NOFOLLOW)` and `renameatx_np`
  implementations, and a second copy is exactly the drift that forced
  `WorkspaceRootContainment` to be extracted in the first place.
- `preview-src` owns static DOM serialization and never gains filesystem authority.
- MarkdownCore remains canonical source/model only. Export v1 needs no new parser.
- The one-shot write is not a WorkspaceKit Save/Save Copy operation and does not weaken
  those retained-authority contracts.
- No new Swift or npm dependency is allowed. Any bridge change obeys `agent.md` §17.5.

## 5. Product Contract (v1)

### 5.1 In scope

| Surface | Contract |
|---|---|
| Export unit | The entire current document from one exact source/file-kind/asset-root/theme snapshot. No selection-only or workspace-batch export. |
| HTML | One static, self-contained `.html` file using D3. No script or live Plainsong bridge. |
| PDF | One `.pdf` file produced silently through D4 after a one-shot save-panel selection. |
| Print | Standard macOS print panel from the same completed offscreen render. |
| Markdown body | The sanitized preview result, including GFM, math, highlighted fences, task-checkbox appearance, and rendered Mermaid. |
| Frontmatter | **Excluded**, matching the current preview body. v1 does not add a frontmatter table/block to exports. |
| MDX | Export the current non-executing preview placeholders: ESM chip rows, JSX component cards, and expression code chips. Never compile or execute user components. |
| MDX/render error | Fail the export with an actionable error. Never export a blank page, the previous document's DOM, or a stale last-good MDX render. |
| Images/styles | D3 exactly for HTML, PDF, and Print. Rejected/over-budget images become inert placeholders; built-in styling/fonts needed for static fidelity are embedded. |
| Theme | Respect the current built-in preview theme at invocation. Resolve `system` to the current light/dark appearance and freeze it in HTML/PDF/Print. |
| Layout modes | Source-only, source+preview, and Experimental WYSIWYG export content-equivalent HTML for the same snapshot and deterministic resources; generated renderer IDs need not be byte-identical. No path may depend on visible-preview layout. |
| Source/session effects | None: no text, selection, scroll, dirty/baseline, identity, recents, workspace tree, or recovery-state mutation. |

### 5.2 Deferred

- Selection-only, multi-document, and whole-workspace export.
- Page headers/footers, custom paper presets, and PDF post-processing.
- Editable/live HTML, embedded Plainsong runtime, or checkbox writeback.
- Any alternative asset packaging mode.

### 5.3 Hard constraints

1. The source, file kind, base directory/root, and resolved theme form one immutable
   operation snapshot. A newer export cancels or supersedes older work; stale results
   cannot write.
2. Only the dedicated offscreen controller may supply output. Visible preview scroll,
   theme, geometry, and DOM are read-only and must remain untouched.
3. `renderComplete` plus D2's correlated `ready(html)` barrier is required. A render/MDX
   failure, stale `renderID`, incomplete resource finalization, PDF failure, or write
   uncertainty is an export failure. Never substitute stale DOM or a partial artifact.
4. The dedicated controller forces remote images off before its first render. No
   HTML/PDF/Print operation performs a remote network fetch or retains an `asset://`,
   `file:`, remote, or workspace-path image source.
5. D3's per-image, aggregate decoded, and final serialized-size limits plus its CSP and
   URL-sink allowlist apply before HTML/PDF/Print success.
6. HTML/PDF uses only the current one-shot panel URL and D5's refusal rules.
7. Protocol v6, mirrored Swift/TypeScript changes, and the regenerated bundle land in
   one commit.
8. Export adds no dependency and never enters the editor typing path.

## 6. Architecture Sketch

Names below are non-binding; capabilities and boundaries are binding.

### 6.1 App operation snapshot

App captures a sendable export request containing exact source text, file kind, source
identity/revision, workspace asset root/base directory, resolved preview theme, output
kind, and a monotonic operation ID. Panel presentation and output writing remain
main-actor orchestrated, while stale/cancel checks fence every suspension.

### 6.2 Offscreen render lifecycle

PreviewKit constructs a fresh controller at export start, installs the snapshot's asset
root/theme, forces remote images disabled before bridge readiness or rendering, submits
one render, and waits for the exact `renderComplete`. The operation owns and releases
this controller. There is no shared visible-WebView fallback.

### 6.3 Static HTML serializer

After exact render completion, Swift begins the protocol-v6 `exportHTML` discovery
round. `preview-src` lists required resources; PreviewKit resolves images and bundled
fonts; Swift returns typed data/omission outcomes in the finalization round.
`preview-src` applies them to the dedicated live DOM and to a static clone, waits for
fonts/images, removes runtime behavior from the clone, enforces D3 bounds/CSP/URL sinks,
and replies with `exportHTMLResult.ready(html)` or failure. Tests parse the returned HTML
and prove it is self-contained and offline. HTML, PDF, and Print all require this one
barrier.

### 6.4 PDF / Print and destination commit

PreviewKit supplies either PDF bytes from `createPDF`/`pdf(configuration:)` with an
explicit rect — one continuous full-content page, or D4's fixed-height pagination if E0
records that the continuous page is unreachable — or a paper-paginated `NSPrintOperation`
from `printOperation(with:)`. App writes HTML/PDF only after the
appropriate save panel returns an exact URL and D5 validation succeeds. Cancellation
destroys the offscreen controller and writes nothing.

## 7. Review-Sized PR Split

One review-sized PR at a time, each branched from then-current `origin/main` and opened
against `main`. Maintainer squash-merges; never push to `main`, force-push, or merge your
own PR.

| PR | Scope | Gates |
|---|---|---|
| **A — spec (this PR)** | `docs/export-gates.md`, one Decision Log row, and the new export-specific R19 row in `docs/risk-register.md` only. No behavior, dependency, menu, bridge, test, or gate-status change. | Closes none |
| **B — mechanism spike** | E0 only: dedicated offscreen controller, exact `renderComplete`, diagnostic nonempty PDF bytes, and visible-scroll non-interference in a production-shaped hosted spike. This is D1's narrow pre-v6 feasibility exception: no File menu, destination write, or production export API. Remove or keep spike code only if its test seam is production-safe. | E0 only |
| **C — bridge + static semantics** | Protocol v6 request/result and shared export-ready barrier, mirrored Swift/TS types, regenerated bundle, successful/stale/error fencing, static document skeleton, frontmatter/MDX/theme/runtime-removal snapshots. No asset inlining, App command, or destination write. | Partial E1–E3 |
| **D — assets + offline fidelity** | PreviewKit resource resolution, deterministic allow/omit outcomes, per-image + aggregate caps, CSS/font embedding, CSP/URL-sink enforcement, finalized live export DOM, and offline hosted reopen. No App File command or destination write. | Closes E2–E3; partial E1/E4 |
| **E — one-shot artifact writer** | Headless exact-URL grant/descriptor service, exclusive new-leaf publication, non-destructive confirmed-overwrite exchange/postflight, authoritative ownership-inventory collision checks, refusal matrix, and fault-injection tests. No menu, panel presentation, render, or document-state mutation. | Partial E6/E9 |
| **F — App HTML export** | Export as HTML… File command, immutable operation snapshot, `NSSavePanel` orchestration through PR E's writer, cancellation/errors/accessibility, and standalone HTML acceptance. | Closes E1; HTML portions of E4/E6–E9 |
| **G — PDF / Print acceptance** | Export as PDF… via `createPDF`; Print… via `printOperation`; full-content/paper-page acceptance, PDF one-shot write through PR E, all-command hosted matrix, performance/security regression, final owner evidence. | Closes E4–E9 remaining work |

D3–D5 owner sign-off is required before PR B starts. If a later implementation needs a
different fixed choice, update this spec and the Decision Log in a separate reviewed
docs PR before changing production behavior.

## 8. Gates

Checkboxes start unchecked. Evidence lines are filled only when the gate closes.

### E0 — Offscreen render + PDF bytes (blocking mechanism spike)

- [x] A dedicated offscreen `PreviewController` becomes ready, renders a named
  Markdown/MDX fixture, and receives `renderComplete` for the exact submitted
  `renderID`.
- [x] The controller receives a nonzero export viewport, and its explicit
  `WKPDFConfiguration.rect` equals the measured full scrollable content bounds.
- [x] A multi-viewport fixture produces nonempty PDF data with a valid `%PDF-` header;
  parsed/extracted output contains distinct first- and last-block sentinels in order, so
  a blank or first-viewport-only PDF cannot pass.
- [x] A fixture whose laid-out content height **exceeds 14,400 pt** (PDF's default
  single-page maximum, per D4) is measured separately, and the observed behavior at and
  beyond that bound is recorded: continuous capture, clipping, scaling, an API failure,
  or an invalid page box. A few-viewport fixture sits far below this bound and cannot
  stand in for it — without this bullet E0 can pass while the continuous-page model is
  already broken for ordinary long-form posts.
- [x] If the continuous page is unreachable past that bound, D4's fixed-height pagination
  fallback is exercised on the same fixture and proves no content is duplicated or
  dropped across page breaks. Record GO for continuous, GO for paginated, or NO-GO.
- [x] The same spike begins while a visible preview is scrolled away from the top and
  proves its scroll position, theme, DOM/render ID, and first responder are unchanged.
- [x] Source-only and Experimental WYSIWYG both succeed without mounting a visible
  preview.
- [x] Failure/timeout/cancellation produces no visible-WebView fallback and no output.
- [x] The PDF-byte call remains diagnostic-only: it has no App/product entry point,
  destination write, or claim that resource readiness is solved before protocol v6.
- Evidence: **GO (paginated)** —
  `testDedicatedOffscreenControllerRendersNamedMarkdownAndMDXAtExactSubmittedRenderIDs`,
  `testExplicitFullContentRectAndNegativeViewportControlProveMultiViewportPDF`,
  `testTallCaptureEnumeratesBoundOutcomeAndPaginatesWithoutDuplicateOrDroppedSentinels`,
  `testVisiblePreviewStateAndFirstResponderRemainUnchangedDuringOffscreenCapture`,
  `testSourceOnlyAndExperimentalWYSIWYGExportWithoutMountingVisiblePreview`,
  `testRenderCompleteAloneIsInsufficientAndFailureTimeoutCancellationReleaseResources`,
  and `testDiagnosticPDFCallStaysTestOnlyInMemoryWithProtocolV5AndNoDestinationWrite`.
  The hosted tall fixture measured **28,816 pt**. Full-rect capture clipped into page
  boxes of **14,400 + 14,400 + 16 pt**; a block-boundary-aware fixed-height plan at
  **14,400 pt** produced three pages with all **420** sentinels exactly once and in
  order. The multi-viewport negative control measured **11,533 pt** against a **600 pt**
  viewport and omitted the last sentinel as required.

### E1 — Immutable snapshot and lifecycle fencing

- [ ] One operation captures exact source, file kind, source identity/revision,
  base-directory/root, resolved theme, and monotonic operation ID.
- [ ] A newer export, document switch/edit, workspace switch/close, or task cancellation
  prevents an older result from reaching a destination write.
- [ ] Render or MDX error fails explicitly; no blank, prior-document, or stale
  last-good DOM is returned.
- [ ] Offscreen controller/task/resources are released on success, failure, and cancel.
- Evidence: _open — PR C/F lifecycle tests_

### E2 — Protocol-v6 export contract

- [ ] Swift and TypeScript list the same 10 ordered message names, including correlated
  `exportHTML` / `exportHTMLResult`, with `PROTOCOL_VERSION == 6`.
- [ ] Discovery/finalization rounds, request/result IDs, and completed `renderID` are
  validated; stale, duplicate, out-of-order, malformed, and failure results cannot
  succeed.
- [ ] `ready(html)` is impossible for current MDX error/stale-last-good DOM, before
  resource outcomes apply, before `document.fonts.ready`, or while a retained image is
  undecoded.
- [ ] `make preview-bundle` output and Swift/TypeScript protocol tests land in the same
  commit as the bridge change.
- [ ] No production path evaluates `document.documentElement.outerHTML` outside the
  typed protocol.
- Evidence: _open — PR C/D bridge, resource-readiness tests, and committed preview bundle_

### E3 — Static HTML and product semantics

- [ ] Output is a parseable complete document (`doctype`, `html`, `head`, `body`) with
  no bridge/runtime script, event handler, or checkbox writeback.
- [ ] Output carries D3's exact CSP; every HTML/SVG URL-bearing attribute and CSS
  `url(...)` is accepted only by the documented scheme/fragment/data allowlist.
- [ ] Markdown kitchen-sink output preserves GFM, math, highlighted code, task-checkbox
  appearance, and Mermaid output.
- [ ] Frontmatter is absent from the body.
- [ ] MDX fixture exports ESM/JSX/expression placeholders without component execution;
  syntax-error/stale-render export fails.
- [ ] `system`, light, and dark themes freeze the correct resolved built-in styling.
- Evidence: _open — PR C/D serializer and policy snapshots_

### E4 — Assets, fonts, and offline fidelity

- [ ] Contained PNG/JPEG/GIF/WebP at exactly the existing ≤ 10 MiB boundary become
  MIME-correct data URIs; cap+1 is rejected.
- [ ] Distinct decoded raster bytes stop at exactly 32 MiB and final HTML UTF-8 stops at
  exactly 64 MiB. Repeated-reference fixtures prove decoded bytes count once but each
  serialized occurrence counts; first-over-limit images become deterministic
  placeholders in stable document order.
- [ ] Traversal, symlink escape, SVG, unsupported, missing/unreadable, malformed/oversize
  authored `data:`, and remote-image fixtures become deterministic inert alt
  placeholders with no original `src`.
- [ ] Exported HTML contains no `asset://`, `file:`, workspace path, remote image URL, or
  sibling resource dependency and renders with networking disabled.
- [ ] KaTeX CSS/fonts and generated KaTeX SVG, highlight.js markup/theme CSS, and
  generated Mermaid SVG/theme survive reopening the standalone file; user-authored SVG
  remains rejected.
- [ ] CSS URL and SVG-href malicious fixtures prove only manifest-known font data and
  same-document generated fragments survive; no external URL sink remains.
- [ ] Resource finalization is complete before HTML/PDF/Print success is reported.
- [ ] A network interceptor proves the dedicated controller issues zero HTTP(S) requests
  during initial render, discovery, finalization, HTML serialization, PDF capture, and
  Print preparation, even when the live-preview remote-image preference is enabled.
- Evidence: _open — PR D/G policy tests + offline hosted reopen_

### E5 — Separate PDF and Print mechanisms

- [ ] Export as PDF… uses `createPDF` / the async `pdf(configuration:)` overlay and
  an explicit rect, writes nonempty valid PDF bytes without opening the print panel, and
  preserves first/last sentinels in order. The page model asserted here is whichever one
  E0 recorded — one continuous full-content page, or D4's fixed-height pagination with no
  content duplicated or dropped across breaks. It is not asserted as continuous
  independently of E0's result.
- [ ] Print… uses `printOperation(with:)` and presents the standard macOS print panel;
  it does not show `NSSavePanel` first.
- [ ] Both use the same completed offscreen snapshot and include finalized images,
  KaTeX, highlighting, Mermaid, MDX placeholders, and resolved theme.
- [ ] Print uses panel-controlled paper pagination; PDF/Print prove equivalent
  content/assets/theme without asserting identical page breaks.
- [ ] Cancel/error paths close their panel/operation cleanly, write nothing, and do not
  touch the visible preview or source session.
- Evidence: _open — PR G hosted PDF/Print tests + owner panel smoke_

### E6 — One-shot sandbox write and refusal matrix

- [ ] HTML/PDF writes use only the exact URL freshly returned by that operation's
  `NSSavePanel`; cancel, denied scope, and stale URL write nothing.
- [ ] A leaf-only grant is never widened implicitly. The Powerbox grant or coordinated
  safe-save mechanism must authorize exact parent/staging work; otherwise the operation
  fails without direct-write or alternate-directory fallback.
- [ ] New-file publication uses `RENAME_EXCL`; owner-confirmed exact-regular-file
  replacement uses `RENAME_SWAP`. Ordinary rename-overwrite and truncating direct write
  are absent. Symlink, directory, device/non-regular, observed identity/type race, and
  unsupported extension fail closed.
- [ ] Overwrite postflight proves the selected writer bytes and exact displaced
  panel-approved identity before cleanup. A mismatch reverses only after exact two-name
  proof; otherwise both identities remain, exact paths are reported, and success is
  impossible.
- [ ] Source collisions reuse the authoritative App ownership inventory from Save Copy
  and mutations, including detached/recovery/indeterminate aliases; hard links and
  case/canonical aliases are rejected.
- [ ] The only allowed sibling is one randomized no-follow operation-scoped staging
  file in the approved parent; success proves it absent. No delivered sibling,
  intermediate directory, persistent recovery journal, bookmark, retry/fallback
  destination, or second artifact is created.
- [ ] Namespace/cleanup uncertainty is reported with exact selected/staging paths and is
  never called an identity-atomic non-commit or a clean success.
- [ ] Write failure/uncertainty is reported as failure and cannot be presented as a
  complete artifact.
- Evidence: _open — PR E–G one-shot write and integration tests_

### E7 — App / File-menu UX and side-effect isolation

- [ ] File commands expose Export as HTML…, Export as PDF…, and Print… only when a
  current exportable document exists, using the existing system File-menu command
  groups without duplicate top-level menus.
- [ ] Save panels have deterministic allowed extensions/default names and never change
  the document URL or Save/Save Copy behavior.
- [ ] Progress, cancellation, render/resource failure, rejected image placeholders, PDF
  failure, and write failure have accessible, non-color-only user feedback.
- [ ] Success/cancel/failure leaves text, selection, scroll, dirty/saved baseline,
  document identity, recents, tree state, and recovery state unchanged.
- Evidence: _open — PR F/G App tests + hosted command/panel smoke_

### E8 — Format, content, theme, and layout matrix

- [ ] Named `.md` and `.mdx` fixtures cover frontmatter, GFM, KaTeX, highlighted fences,
  Mermaid, task checkboxes, allowlisted/ineligible images, and MDX placeholders.
- [ ] Source-only, source+preview, and Experimental WYSIWYG produce content-equivalent
  static HTML for the same deterministic snapshot/resources and content/theme-equivalent
  PDF/Print output; the E0-recorded PDF page model versus paper-Print pagination is
  intentionally different.
- [ ] Light, dark, and resolved-system themes match the current preview theme without
  mutating the visible preview.
- [ ] A current-render error and an MDX stale-last-good state fail rather than exporting
  prior content.
- Evidence: _open — PR C–G hosted format/layout matrix_

### E9 — Accessibility, performance, security, and regression

- [ ] Stable accessibility identifiers/labels cover all three commands, save panels,
  progress/cancel, omission notice, and errors; keyboard-only HTML/PDF/Print flows pass.
- [ ] Measure the production offscreen path with a large document, code-heavy/KaTeX/
  Mermaid fixture, and many bounded raster assets in Debug and Release before freezing
  any export-specific wall-clock or memory budget.
- [ ] Export work never enters the editor keystroke path; the existing < 16 ms typing
  budget remains green while export is active.
- [ ] Existing preview protocol, asset containment, MDX sanitizer, theme, render,
  scroll-sync, Save/Save Copy, and workspace mutation/recovery suites remain green.
- [ ] Dependency manifests are unchanged.
- Evidence: _open — PR G measured evidence + full regression suite_

## 9. Performance and Security Acceptance

| Area | Rule |
|---|---|
| Measure first | Record Debug and Release samples for the production offscreen render, HTML serialization, PDF generation, and active-export typing latency before freezing export budgets. |
| Fixture shape | Include `Fixtures/large-1mb.md`, code/KaTeX/Mermaid-heavy content, MDX placeholders, and enough allowlisted raster assets to exercise repeated inlining. |
| Existing/new hard bounds | Per-image raster allowlist and ≤ 10 MiB cap, 32 MiB distinct decoded raster aggregate, 64 MiB final HTML UTF-8, path/symlink containment, user-SVG rejection, export CSP/URL-sink allowlist, no remote export fetch, and no new dependency are non-negotiable. |
| CI discipline | Deterministic correctness/security assertions are hard everywhere. Wall-clock numbers follow R15: hard locally and informational on hosted CI unless later evidence supports a stable hosted threshold. |
| Failure | Timeout, cancellation, stale render, resource-finalization failure, PDF error, or write uncertainty produces no claimed artifact and no visible-preview/source mutation. |

Do not invent or widen an export budget to rescue a failing run. Changing D3's aggregate
limits requires measured evidence plus an owner-approved Decision Log entry before
implementation ships.

## 10. Non-Goals

- No publish integrations.
- No custom export templates.
- No user CSS.
- No MDX component execution.
- No batch/workspace, selection-only, EPUB, or source-text PDF export.
- No alternative asset-folder/relative-path mode.
- No change to frontmatter rendering, preview sanitization, remote-image preference,
  workspace Save/Save Copy, or Experimental WYSIWYG promotion.

## 11. Sign-Off

| Role | Responsibility |
|---|---|
| Implementer | Keep all boxes unchecked until the owning PR carries the named evidence; stop at E0 failure; obey D1–D5 without silent fallback. |
| Owner | Explicitly sign off **D3 self-contained asset/style policy**, **D4 separate PDF/Print workflows**, and **D5 one-shot filesystem-authority exception** before PR B begins; run the Print-panel/product smoke in E5. |
| Maintainer | Review/squash-merge each PR after green required checks; never rely on the author to merge their own PR. |
