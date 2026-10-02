# Phase 3 Export (HTML / PDF / Print) — Gate Specification

> **Status: E0 mechanism gate closed as GO (paginated). Owner signed off D3–D5 on
> 2026-08-13 using the specified defaults (D4 page model is the E0 paginated fallback).
> PR C landed the static-document skeleton. PR D closes E2–E3 and the HTML portion of
> E4; E1 stays partial. PR E lands the headless one-shot WorkspaceKit artifact writer
> (writer-level E6 bullets except the sibling bullet, and the E9 dependency bullet; the
> E6 bullets are reopened below by the D5 amendment).
> The rest of E5–E9 remains open. PR D's review fixes add an optional `dataURIFrom`
> reference to resource outcomes, so `PROTOCOL_VERSION` is 8.
> D5 amended 2026-09-29: PR F Phase A's owner smoke proved that a leaf-only save-panel
> grant cannot open the chosen folder (`parentAuthorityUnavailable` on `~/Desktop` and
> `~/Documents`). Staging moves to a same-device item-replacement directory with
> exact-leaf publication, proven by an owner-run DEBUG probe. The E6 mechanism bullets
> proven against the retired parent-anchored writer, including the ownership inspection
> (which is parent-descriptor-derived), were reopened for PR E2, and PR F waits for E2.
> PR E2 (2026-09-30) replaces the writer with the amended-D5 leaf-path writer and moves the
> ownership inspection to leaf-path metadata; it re-proves every reopened E6 bullet and the
> rewritten sibling bullet. The leaf-grant bullet (PR F's owner smoke) and the
> fresh-panel-URL bullet (PR F) stay open.
> PR F Phase B (2026-10-01) closes E1 and the automated HTML portions of E4/E7/E8.
> E6's real-panel/leaf-grant owner smoke, keyboard-only acceptance, PDF/Print portions,
> and E9 performance remain open. Owner checklist and exact test/measurement commands:
> `docs/export-html-phase-b-checklist.md`.** Precedent:
> PR #45 and PR #95. Every E0–E9 checkbox may be checked only with named test evidence
> or an owner-recorded result in the same commit.

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
| **D5** | One-shot `NSSavePanel` destination, deliberately outside the retained workspace-file write path. Staging and publication mechanism amended 2026-09-29: same-device item-replacement staging plus exact-leaf publication. | **Required.** The amendment needs owner approval of its docs PR. |

**Owner sign-off 2026-08-13:** D3, D4, and D5 are accepted as specified. D4’s v1 page
model is the E0-recorded fixed-height pagination, not a continuous page. This unlocks
implementation PR C; it is not itself a product-surface change. Silence, implementation
activity, or a green CI run remains insufficient for any later change to these choices.

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
  typed discovery or finalization phase, and an optional parsed frontmatter `documentTitle`.
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

#### Document title

The static `<title>` uses the non-empty MarkdownCore-parsed frontmatter `title`,
otherwise the first document heading (`h1`–`h6` in document order, excluding headings
inside MDX component cards), otherwise `Untitled`. Frontmatter remains absent from the
body. Swift sends the optional frontmatter title in both v6 export rounds; JS retains
that discovery value while choosing the rendered-heading fallback.

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

**Amended 2026-09-29: staging and publication mechanism.** A save-panel grant covers
exactly the chosen leaf path. It is not authority over the leaf's folder. The original
text of this section staged a random sibling file inside the chosen folder through held
no-follow parent descriptors. The owner's PR F Phase A smoke (evidence below) proved that
design unusable outside folders the app already holds: opening the chosen parent is
refused with `parentAuthorityUnavailable` for `~/Desktop` and `~/Documents`, so nothing
can be written there. The operation therefore never opens, enumerates, or creates entries
in the chosen folder, other than publishing the leaf itself:

1. **Staging location.**
   - Stage in `FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
     appropriateFor: leaf, create: true)`. This is an operation-private directory that
     Foundation chooses for the destination's volume; on the internal APFS volume it was
     observed inside the app container.
   - Prove it is a directory on the same `st_dev` as the destination:
     - for a confirmed overwrite, compare against the existing leaf;
     - for a new leaf, compare against the metadata of the leaf's parent path. The probe
       observed this metadata read succeed; it is never an open or an enumeration.
   - Read the volume-capability keys from the existing leaf for an overwrite, and from the
     parent URL for a new leaf (querying a missing leaf throws `ENOENT`).
   - Fail closed, before writing any byte, when:
     - the directory is on a different device;
     - the directory is unavailable;
     - the returned directory is the chosen folder or lies inside it (Foundation has a
       fallback that creates a "(A Document Being Saved By …)" folder beside the target);
     - the destination volume does not advertise both exclusive and swap renaming
       (`volumeSupportsExclusiveRenaming` / `volumeSupportsSwapRenaming`).
   - There is no cross-device copy fallback.
   - **Owner decision 2026-09-30 (E2 review): containment.** In the sandbox, the
     item-replacement directory lives under `~/Library/Containers/<id>/Data`, so the rule
     above refused exports to the home-folder root (`~/x.html`). It is replaced by this rule.
     Staging is accepted only when either:
     - (a) the returned directory is not inside the chosen folder at all; or
     - (b) all of the following hold:
       - it lies strictly inside an injected app-private root (the sandbox container's data
         directory, supplied by App only when running sandboxed; otherwise there is none);
       - the chosen folder is a proper ancestor of that root;
       - it is neither the chosen folder nor a direct child of it.

     Everything else stays refused, including:
     - staging inside a chosen folder that is equal to or inside the app-private root (a
       chosen folder there is fine when the staging directory lies outside it, under rule (a));
     - a direct child of the chosen folder;
     - a directory inside the chosen folder but outside the root.

     The root must already exist before staging begins: it is proven to be a directory with no
     symlink anywhere (`AT_SYMLINK_NOFOLLOW_ANY`, final component included) before Foundation is
     asked for a directory, so Foundation's `create: true` cannot have created it. If it cannot be
     proven, only rule (a) applies.

     Spellings are compared canonically:
     - the staging directory and the root via `getattrlist(ATTR_CMN_FULLPATH)`;
     - the chosen folder as proven by the leaf proof;
     - component by component.

     The chosen folder therefore never gains a new visible entry: anything created lies below
     pre-existing `Library/Containers/…` directories.
2. **Staged bytes.** Create exactly one staged file there with `open(O_CREAT | O_EXCL |
   O_NOFOLLOW | O_WRONLY)`, write and `fsync` the complete artifact, and record its
   `st_dev`/`st_ino` identity.
3. **Leaf proof.** Inspect the exact panel URL path with
   `fstatat(AT_FDCWD, leaf, …, AT_SYMLINK_NOFOLLOW_ANY)`, so no path component may be a
   symlink; the parent path must be a directory.
   - absent → the new-leaf disposition;
   - a regular file whose identity equals the one the panel approved → the
     confirmed-overwrite disposition;
   - anything else fails closed:
     - a symlink, a directory, a device or FIFO;
     - a case or normalization alias of an existing entry;
     - an identity or type change since panel inspection.

   Repeat this proof immediately before publication.
4. **Publication by path.**
   - New leaf: `renameatx_np(AT_FDCWD, staged, AT_FDCWD, leaf, RENAME_EXCL |
     RENAME_NOFOLLOW_ANY)`.
   - Confirmed overwrite: the same call with `RENAME_SWAP | RENAME_NOFOLLOW_ANY`. This
     leaves the displaced original at the staged name inside the item-replacement directory.
   - Still forbidden: ordinary rename-overwrite, truncating direct write, and destructive
     fallback.
5. **Postflight.**
   - Inspecting without following links proves the leaf holds the staged identity. For a
     swap, it also proves the staged name holds the exact panel-approved displaced identity.
   - Only then unlink the displaced original and remove the item-replacement directory.
     Success requires proving both are absent.
   - If postflight finds a mismatch, a reverse swap is allowed only after an exact two-name
     proof.
   - Otherwise preserve both identities and report committed-but-indeterminate, with the
     exact leaf path and the exact item-replacement path.
   - When the item-replacement path holds the user's displaced original, the report must say
     so plainly. It is a hidden temporary location inside the app container, which the OS may
     purge (not verified), so the user should recover the file promptly. PR E2 must not claim
     that location is durable.
   - There is no automatic retry or cleanup.
6. **Accepted residual.**
   - The chosen parent is never held, so there is no parent-namespace stability proof. The
     window between the last inspection and `renameatx_np` is name-based. It is bounded by:
     - `RENAME_EXCL`, which never clobbers an entry that appears in that window;
     - `RENAME_NOFOLLOW_ANY`, which refuses a symlinked path component;
     - swap postflight, which detects an unexpected displaced identity.
   - The chosen parent cannot be `fsync`ed. After a crash, the rename's durability relies on
     the filesystem's metadata ordering rather than an explicit parent sync (the retired
     writer synced the parent).
   - Indeterminate residue lives in a temporary, possibly purgeable location (step 5).
   - These name-based operations are not described as identity-atomic.

The same mechanism serves every panel destination, including folders inside an open
workspace. The parent-anchored export path is therefore retired, not kept as a second mode.

This also applies to the App ownership inspection. Today it derives the destination's
identity, canonical spelling, and case sensitivity from parent descriptors:
`WorkspaceFileSystemLocation(fileURL:)`, `inspectFileTarget`, and `parentIsCaseSensitive`
all go through `withAnchoredParent`. Under a leaf-only grant it would therefore refuse
Desktop and Documents too. PR E2 must derive these from leaf-path metadata instead, while
keeping the same authoritative inventory and outcome types. Candidate sources, to be
proven in E2:
- `fstatat` identity;
- `fcntl(F_GETPATH)` on an opened existing leaf for canonical spelling;
- the parent URL's `volumeSupportsCaseSensitiveNames`.

Authority lifetime is unchanged:
- nothing is bookmarked or journaled;
- the item-replacement directory and the leaf authority are released when the operation
  ends.

**D5 amendment evidence (owner Mac, 2026-09-29, macOS 27.0 26A428, sandboxed Debug):**

| Run | Destination | Result |
|---|---|---|
| PR F Phase A (`phase3-export-html-command` 7edc45d, parent-anchored writer) | (a) folder inside the open workspace | Pass |
| | (b) `~/Desktop` | Refused at inspection: `ExportArtifactFailure.parentAuthorityUnavailable`; nothing written |
| | (c) `~/Documents` | Same as (b) |
| Staging probe (DEBUG-only, `phase3-export-staging-probe` bc6c097, not merged) M1 = the mechanism above | `~/Desktop`, new leaf | `RENAME_EXCL` = 0; leaf holds the staged identity; staged name absent; directory removed (`rmdir` = 0) |
| | `~/Documents`, new leaf | Same |
| | `~/Desktop`, panel-confirmed overwrite | `RENAME_SWAP` = 0; leaf holds the staged identity; staged name holds the original inode; displaced original unlinked; directory removed (`rmdir` = 0) |
| | iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs`, `isUbiquitousItem(parent) = true`) | Same as the new-leaf rows, uncoordinated |
| | The PR F (a) folder, `~/plainsong-export-smoke/exports` (control) | Same |

In every probe run:
- the item-replacement directory was inside the app container, on the same `st_dev` as
  the destination;
- `lstat` of the parent path succeeded;
- `lstat` of the leaf returned the file, or `ENOENT` for a new leaf, and never `EPERM`.

The probe's M2 comparison (`FileManager.replaceItemAt`) also passed everywhere. The probe
did not exercise the ownership inspection. External volumes were not tested.

**Owner decisions (2026-09-29):**
- **Q1 — iCloud: coordinate.** When the destination is ubiquitous, PR E2 wraps
  publication in `NSFileCoordinator.coordinate(writingItemAt: leaf, options: .forReplacing)`.
  The probe succeeded uncoordinated, but Apple documents coordinated writes for ubiquitous
  items. Coordination is an addition; it grants no sandbox authority.
- **Q2 — external volumes: accepted as untested.** PR E2 fails closed on cross-device
  staging and on missing exclusive/swap-rename support. PR F's owner smoke case (e) records
  real external-volume evidence.
- **Q3 — file mode: decided.** The retired writer created `0600`, like Save Copy; the
  probe used `0644`. PR E2 does this:
  - a new leaf gets the process umask default (`0666 & ~umask`, normally `0644`), matching
    other macOS apps' saved files;
  - a confirmed overwrite keeps the displaced file's permission bits, as `NSDocument` does.

  A `0600` HTML file uploaded with permission-preserving tools (`rsync -a`, `scp -p`) is
  unreadable by a web server.

The exception is narrow. The export path must still refuse to:

1. Write in any of these cases:
   - without a fresh successful panel result;
   - after cancellation;
   - when the exact panel leaf or a same-device item-replacement directory cannot be
     established (amended 2026-09-29);
   - by falling back to a direct write or another directory.
2. Follow a symlink or replace a directory, device, or other non-regular destination. A
   new leaf must use exclusive publication; a confirmed overwrite may swap only with the
   exact regular-file identity approved by the panel. Every observed identity/type change
   before publish fails closed, and every unexpected post-swap identity is preserved.
3. Overwrite any identity returned by the existing authoritative App ownership inventory
   used by Save Copy and workspace mutations—not a new export-specific URL list. That
   inventory includes current, warm/cached, retired, quarantined/detached, editor-bound,
   context-only, recovery, and indeterminate aliases. Comparison includes hard links and
   the filesystem's case/canonical aliases, not only URL-string equality.
4. Intentionally create a delivered sibling asset/font file, intermediate directory,
   persistent recovery journal, or second export output. The writer's own temporary entries
   are the operation-private item-replacement directory and its single staged file
   (amended 2026-09-29; shared-ancestor reporting clarified 2026-10-01):
   - These are the only operation-owned temporary entries. If Foundation places that directory
     in the chosen folder
     (its fallback creates it before any check can run), fail closed. Remove the directory
     only if it is empty and its identity matches; otherwise report its exact path. The one
     exception is a directory below the app-private root under step 1's owner decision of
     2026-09-30: it adds no entry to the chosen folder itself.
   - Foundation can also create shared ancestors such as `.TemporaryItems/folders.<uid>`
     before containment runs. Their tracked namespace uncertainty is reported by exact
     `unprovenDirectoryURLs` under E6; those ancestors are never deleted or assumed to be
     operation-owned. A universal no-extra-entry observation remains an owner sandbox smoke.
   - Neither operation-owned entry may survive a reported success.
   - Either operation-owned entry may remain only after a truthfully reported indeterminate
     failure, at an exact reported path, so that no identity is destroyed.
5. Rekey a session, mark source saved/clean, change recents, adopt the export as the
   current document, or enter the workspace mutation/recovery journal.
6. Retry silently at an old/stale URL or treat a partial/uncertain write as success.

**Rejected:**
- **The retained workspace mutation API.** Routing exports through it would misclassify a
  derived one-shot artifact as canonical workspace state, and would retain authority the
  user did not ask Plainsong to keep.
- **A broad, uncoordinated URL write.** The one-shot path stays exact-leaf, fail-closed,
  and side-effect-free on the document.

Also rejected by the 2026-09-29 amendment:
- **Keeping parent-anchored sibling staging.** The owner smoke shows a leaf grant cannot
  open the parent.
- **Asking the user to grant the containing folder**, for example with a second open
  panel. That is non-standard export UX and wider authority than one artifact needs.
- **Writing or truncating directly into the leaf.** A failure leaves a partial file, and an
  overwrite destroys the original before the new bytes are proven.
- **`FileManager.replaceItemAt` as the production primitive.** It passed the probe, but its
  internal backup and cleanup cannot provide D5's exact displaced-identity proof or its
  indeterminate-path reporting.
- **`NSFileCoordinator` as the authority mechanism.** Coordination grants no sandbox
  authority. It is considered only as an additional wrapper for ubiquitous destinations
  (Q1).

**Owner sign-off:** Required because this is an explicit, narrowly bounded exception to
the repository's strongest filesystem-authority policy. The 2026-09-29 mechanism amendment
needs owner approval of its docs PR. Q1–Q3 were answered 2026-09-29.

## 4. Layering

```text
App
  File commands, exact document snapshot, NSSavePanel / NSPrintOperation orchestration,
  one-shot write result and user-visible errors
    PreviewKit                          WorkspaceKit
      offscreen PreviewController         one-shot non-retained artifact writer:
      lifecycle, render/result fencing,   item-replacement staging + exact-leaf
      asset:// policy, WKWebView          RENAME_EXCL / RENAME_SWAP publication with
      PDF and print APIs                  no-follow fstatat proofs (D5, amended 2026-09-29)
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
  WorkspaceKit already owns the only audited `renameatx_np` and identity-proof
  implementations. A second copy is exactly the drift that forced
  `WorkspaceRootContainment` to be extracted in the first place. The amended D5 leaf-path
  publication stays in WorkspaceKit beside those primitives.
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
| **E2 — leaf-path writer (D5 amendment, 2026-09-29)** | Replace PR E's parent-anchored publication with amended D5: same-device item-replacement staging, exact-leaf no-follow `fstatat` proofs, and `RENAME_EXCL` / `RENAME_SWAP` by path with `RENAME_NOFOLLOW_ANY`. Also: the postflight, reverse-swap, and indeterminate reporting that includes the item-replacement path; fail-closed cross-device or unsupported-volume handling; Q1–Q3 decisions; and fault-injection tests. Rework the ownership inspection so that identity, canonical leaf name, and case sensitivity come from leaf-path metadata; keep the authoritative inventory and the typed outcome. No menu or render change. | Re-proves the reopened E6 bullets, including ownership; the sibling bullet |
| **F — App HTML export** | Export as HTML… File command, immutable operation snapshot, `NSSavePanel` orchestration through PR E2's writer, cancellation/errors/accessibility, and standalone HTML acceptance. | Closes E1; HTML portions of E4/E6–E9 |
| **G — PDF / Print acceptance** | Export as PDF… via `createPDF`; Print… via `printOperation`; full-content/paper-page acceptance, PDF one-shot write through PR E2's writer, all-command hosted matrix, performance/security regression, final owner evidence. | Closes E4–E9 remaining work |

D3–D5 owner sign-off was recorded 2026-08-13 (after E0, before PR C). If a later
implementation needs a different fixed choice, update this spec and the Decision Log in
a separate reviewed docs PR before changing production behavior.

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

- [x] One operation captures exact source, file kind, source identity/revision,
  base-directory/root, resolved theme, and monotonic operation ID.
- [x] A newer export, document switch/edit, workspace switch/close, or task cancellation
  prevents an older result from reaching a destination write.
- [x] Render or MDX error fails explicitly; no blank, prior-document, or stale
  last-good DOM is returned.
- [x] Offscreen controller/task/resources are released on success, failure, and cancel.
- PR C evidence: `ExportHTMLLifecycleTests` covers cancellation (including pre-cancel),
  timeout (production default 15 seconds), explicit `invalidate()`, the WebContent
  termination delegate callback, bridge-send failure, supersession, and shared render
  readiness. The four terminal lifecycle cases assert pending-continuation removal and
  weak controller/WebView release after owner invalidation. This injects the termination
  notification; it does not kill an OS WebKit helper. `ExportHTMLHostedTests` rejects
  MDX stale/error output. PR D adds `testResourceResolutionTaskIsCancelledWhenExportFinishes`,
  which cancels the off-main resource-read task when the export finishes. App snapshot and
  destination-write fencing remained PR F at that stage; the Phase B evidence below closes them.

- PR F Phase B evidence: `ExportHTMLCommandAppTests` closes snapshot/lifecycle
  integration with `testSnapshotCapturesExactSourceRevisionAssetsThemeAndMonotonicIdentity`,
  `testDocumentEditWhileThePanelIsOpenPreventsTheWrite`,
  `testSupersedingExportPreventsTheOlderWrite`,
  `testDocumentSwitchAndCloseFenceBothPanelAndPreparedArtifact`,
  `testWorkspaceCloseAndEditFenceThePreparedArtifact`,
  `testSwitchAwayAndBackStillFencesTheExport`,
  `testClosingTheOriginWindowFencesThePreparedArtifact`,
  `testPanelCancelAndProgressCancelAreSilentAndReleaseTheController`, and
  `testWeakControllerAndWebViewAreReleasedAfterSuccessFailureAndCancel`.
  `testMDXSyntaxErrorFailsWithoutWriting` plus PreviewKit's
  `testMDXSyntaxErrorFailsInsteadOfExportingLastGoodDOM` close the error bullet.
  Title/default-name parsing is off-main against captured source; every await is fenced,
  and only the final synchronous `writeExportArtifact` call may publish.

### E2 — Protocol-v6 export contract

- [x] Swift and TypeScript list the same 10 ordered message names, including correlated
  `exportHTML` / `exportHTMLResult`, with `PROTOCOL_VERSION == 8`.
- [x] Discovery/finalization rounds, request/result IDs, and completed `renderID` are
  validated; stale, duplicate, out-of-order, malformed, and failure results cannot
  succeed.
- [x] `ready(html)` is impossible for current MDX error/stale-last-good DOM, before
  resource outcomes apply, before `document.fonts.ready`, or while a retained image is
  undecoded.
- [x] `make preview-bundle` output and Swift/TypeScript protocol tests land in the same
  commit as the bridge change.
- [x] No production path evaluates `document.documentElement.outerHTML` outside the
  typed protocol.
- Ordered-name/version evidence: `preview-src/test/protocol.test.ts` and
  `PreviewKitTests.testBridgeProtocolVersionAndMessageOrder` pin the ten ordered names
  and version 8. PR D's review fixes bumped 7 → 8 because a repeated accepted image's
  outcome now names the first outcome through `dataURIFrom` instead of repeating its
  data URI (`ExportHTMLProtocolTests.testRepeatedEmbedOutcomeReferencesTheFirstDataURIRoundTrip`;
  JavaScript rejects forward, dangling, chained, or doubly specified references in
  `export-html-hardening.test.ts`). `ExportHTMLProtocolTests` covers the mirrored title payload;
  `ExportHTMLBridgeDecodingTests` checks direct dictionary decoding against Codable,
  malformed rejection, and a multi-MB receipt. Early ready, duplicate discovery,
  and superseded results stay fenced; duplicate discovered resource IDs fail before
  resolution (`ExportHTMLLifecycleTests.testDuplicateDiscoveredResourceIDsFailBeforeResolution`),
  and finalization fails with `resources-changed` if the image DOM no longer matches
  discovery (`export-html-hardening.test.ts`). PR D readiness evidence is
  `export-html.test.ts` (finalization-before-ready and MDX stale/error),
  `export-html-review.test.ts` (fonts and style collection must settle), and
  `export-html-assets.test.ts` (`does not emit ready before image decode resolves`).
  An image WebKit cannot decode becomes its placeholder and export continues; `ready`
  still requires every retained image to be a decoded candidate
  (`export-html-hardening.test.ts`, finding 4 cases). That proof decodes each distinct
  data URI once in the export WebContent process. The finalized live-DOM `<img>` nodes
  are inserted synchronously right before `ready` and are not decoded in place, so
  **PR G must await `decode()` on those live nodes before PDF or Print capture** (D2
  barrier item 3).
  The static document is built by `buildStaticExportHTML`; production export does not
  read `document.documentElement.outerHTML`. The regenerated preview bundle is in this
  commit. E2 is closed.

### E3 — Static HTML and product semantics

- [x] Output is a parseable complete document (`doctype`, `html`, `head`, `body`) with
  no bridge/runtime script, event handler, or checkbox writeback.
- [x] Output carries D3's exact CSP; every HTML/SVG URL-bearing attribute and CSS
  `url(...)` is accepted only by the documented scheme/fragment/data allowlist.
- [ ] Markdown kitchen-sink output preserves GFM, math, highlighted code, task-checkbox
  appearance, and Mermaid output.
- [x] Frontmatter is absent from the body; `<title>` follows D3's frontmatter / first
  document heading / `Untitled` rule.
- [x] MDX fixture exports ESM/JSX/expression placeholders without component execution;
  syntax-error/stale-render export fails.
- [x] `system`, light, and dark themes freeze the correct resolved built-in styling.
- PR C evidence: `ExportHTMLTitleTests` and `export-html-review.test.ts` cover title
  precedence, a non-leading H2, MDX component-card headings before the document heading,
  CSS closing-tag injection, exception-to-failure results, inline raster preservation,
  shared image MIME policy, and superseded discovery without export resource attributes.
  Only a successful finalization writes the finalized static nodes into the dedicated
  offscreen export DOM, synchronously before `ready`; failed or superseded exports leave
  it untouched (`export-html-hardening.test.ts`, finding 8 case).
  `ExportHTMLHostedTests.testSuccessfulMarkdownExportIsAStaticDocument` requires
  `--preview-bg`, defined in the bundled CSS, instead of accepting the root element.
  WebKit refuses CSSOM reads of linked file-origin stylesheets; `build.mjs` supplies
  the exact same CSS input as `bundle.css`, while readable renderer-injected styles
  still come from CSSOM. No export-time fetch occurs. Inline raster preservation here
  now goes through Swift normalization. PR D evidence: `export-html-assets.test.ts`
  pins the exact CSP and URL/SVG sinks. The review fixes replace the CSS `url()` regular
  expression with a CSS-syntax scanner: `export-html-hardening.test.ts` drops `@import`
  (including escaped `@\69mport`), neutralizes `image-set()`, escaped `u\72l(`, and
  url values containing `)` or quotes, fails closed on unterminated url(), and sanitizes
  generated-SVG `style` and presentation attributes. `<` is escaped before the scan, so
  nothing transforms the scanner's output: escaping afterwards had turned `\<url(` into
  `\\3c url(`, a live url() token. `export-css-urls.test.ts` covers that vector in head
  CSS, an SVG `<style>`, and a `style` attribute, and re-scans the sanitized output of
  25,745 generated escape, comment, backslash-newline, custom-property, and `var()`
  inputs to find only `url()`, fragments, or manifest fonts. A malformed url() keeps the
  enclosing `}` so later rules survive.
  `ExportHTMLOfflineTests.testEscapedLessThanURLSinksStayNeutralInTheReopenedDocument`
  reopens the export in WebKit and checks its CSSOM and computed styles: with the
  previous sanitizer, `list-style-image` resolved to the remote URL.
  `ExportHTMLHostedTests` covers the static
  document, disabled checkboxes, MDX placeholders, and MDX failure;
  `export-html.test.ts` freezes dark styling; `ExportHTMLOfflineTests` resolves `system`
  to light or dark. The full `Fixtures/kitchen-sink.md` matrix stays open for E8, so
  E3 stays open on that bullet only.

### E4 — Assets, fonts, and offline fidelity

- [x] Contained PNG/JPEG/GIF/WebP at exactly the existing ≤ 10 MiB boundary become
  MIME-correct data URIs; cap+1 is rejected.
- [x] Distinct decoded raster bytes stop at exactly 32 MiB and final HTML UTF-8 stops at
  exactly 64 MiB. Repeated-reference fixtures prove decoded bytes count once but each
  serialized occurrence counts; first-over-limit images become deterministic
  placeholders in stable document order.
- [x] Traversal, symlink escape, SVG, unsupported, missing/unreadable, malformed/oversize
  authored `data:`, and remote-image fixtures become deterministic inert alt
  placeholders with no original `src`.
- [x] Exported HTML contains no `asset://`, `file:`, workspace path, remote image URL, or
  sibling resource dependency and renders with networking disabled.
- [x] KaTeX CSS/fonts and generated KaTeX SVG, highlight.js markup/theme CSS, and
  generated Mermaid SVG/theme survive reopening the standalone file; user-authored SVG
  remains rejected.
- [x] CSS URL and SVG-href malicious fixtures prove only manifest-known font data and
  same-document generated fragments survive; no external URL sink remains.
- [x] Resource finalization is complete before HTML/PDF/Print success is reported.
- [x] HTML: a network interceptor proves zero HTTP(S) requests across initial render,
  discovery, finalization, serialization, and standalone reopen, even with the live
  remote-image preference enabled.
- [ ] PDF capture and Print preparation issue zero HTTP(S) requests under an interceptor.
- Evidence: `ExportResourceResolverTests` (10 MiB PNG boundary, JPEG/GIF/WebP MIME,
  32 MiB distinct bytes, repeated references, traversal/symlink/SVG/remote/data-URI
  rejection, manifest woff2), `ExportResourceResolverReviewTests` (100 references to one
  image carry its data URI once across the bridge; header-only and corrupt PNG/JPEG
  that still type-sniff are omitted because acceptance now requires an ImageIO decode;
  repeated authored `data:` images are answered before any decode),
  `export-html-assets.test.ts` (exact 64 MiB HTML, per-image serialized cap measured
  on the sanitized document, URL sinks, user SVG removal), `export-css-urls.test.ts`
  and `ExportHTMLOfflineTests.testEscapedLessThanURLSinksStayNeutralInTheReopenedDocument`
  (CSS URL sinks, including the escaped-`<` vector, stay neutral in WebKit),
  `export-html-hardening.test.ts`
  (an image without a validated outcome fails closed to its placeholder, font IDs never
  collide, and the budget agrees with the final length check), and
  `ExportHTMLOfflineTests.testOfflineReopenRendersEmbeddedResourcesWithoutNetwork`
  (custom-scheme reopen; image, KaTeX, highlight, and Mermaid render; one document
  request). The zero-HTTP interceptor across PDF and Print stays with PR G, so E4
  remains partial.

- PR F HTML interceptor evidence:
  `ExportNetworkInterceptorTests.testExportIssuesNoHTTPRequestsEvenWhenTheLivePreviewAllowsRemoteImages`
  (Markdown and MDX) and the sandboxed App's
  `ExportHTMLOfflineTests.testProductCommandAndWrittenHTMLIssueZeroHTTPRequestsWithLiveRemotePreferenceOn`.
  Both refuse loopback proxy tunnels and then prove the live-preview positive control
  reaches that recorder. The App test installs its proxy data store before constructing
  the export controller; its unblocked positive control uses the same pre-construction
  data-store setup and must record the `.invalid` host request. The App test reopens the actual written file without the
  export content blocker and verifies embedded image, math, code, and Mermaid.
  `PreviewController.makeHTMLExportController` installs its HTTP(S) content rule before
  the bundled page loads: detached images can initiate a load before JS rewrites them.

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

PR F supporting automation (not Powerbox evidence):
`testEveryInvocationRequiresAFreshPanelResultAndNeverReusesACancelledDestination`,
`testPanelCancelAndProgressCancelAreSilentAndReleaseTheController`,
`testDestinationIdentityCapturedAtPanelReturnCannotReplaceARacedLeaf`, and the E1
stale-operation tests. Both owner-dependent boxes below stay open. The eight real-panel
cases are all unchecked in `docs/export-html-phase-b-checklist.md`.

> **2026-09-29 D5 amendment:** Every bullet below that PR E's evidence checked was proven
> against the now-retired parent-anchored writer, so all five were reopened until PR E2
> re-proved them on the leaf-path mechanism: `RENAME_EXCL`/`RENAME_SWAP` publication,
> overwrite postflight, ownership inspection, uncertainty paths, and failure reporting.
> **PR E2 (2026-09-30)** re-proves them, and the rewritten sibling bullet, with the named
> tests in the PR E2 evidence below. The leaf-grant bullet stays open for PR F's owner smoke.

- [ ] A leaf-only grant is never widened implicitly:
  - the operation never opens or enumerates the chosen folder, and never gives it a new entry
    other than the leaf (a staging directory may lie below it only inside the app-private
    root, per D5 step 1's owner decision of 2026-09-30);
  - staging lives only in a same-device, operation-private item-replacement directory;
  - if that directory cannot be established, the operation fails without a direct-write or
    alternate-directory fallback.

  Mechanism evidence: the D5 amendment probe (owner, 2026-09-29). Production evidence:
  PR E2 tests plus PR F's owner smoke. PR E2 supporting evidence (a simulation, not a
  Powerbox grant): `testWriteOnlyParentPublishesWithoutEverOpeningTheChosenFolder` and the
  hosted `testWriteOnlyParentNeedsNoParentHandleForOwnership` (mode `0300` parent: its
  `open(O_RDONLY)` fails with `EACCES`; every writer call on the chosen folder is an
  `fstatat` or `getattrlist` metadata read, and no descriptor names it at any boundary),
  `testUnavailableItemReplacementDirectoryFailsClosedWithoutFallback`,
  `testStagingInsideTheAppPrivateRootIsAcceptedWhenTheChosenFolderIsItsAncestor` (a fake
  home and container layout). Open until PR F's owner smoke records a real save-panel grant,
  covering these cases under the real sandbox (record each outcome):
  - **The home-folder root (`~/x.html`)**, which exercises containment rule (b).
  - **An accented folder created with Terminal (`mkdir café`)**: export a new file into it, and
    an overwrite. Foundation can rebuild path-string URLs in NFD, so an NFC on-disk name may be
    falsely refused as `destinationAlias` by the byte-exact rule. The record decides whether
    NFC/NFD adoption is relaxed; that is an owner decision, not part of PR E2.
  - **An external volume's root**: unsandboxed, Foundation may create
    `.TemporaryItems/folders.<uid>/` at the volume root before the writer refuses. Record
    whether that happens under the sandbox.
- [x] New-file publication uses `RENAME_EXCL | RENAME_NOFOLLOW_ANY`, and owner-confirmed
  exact-regular-file replacement uses `RENAME_SWAP | RENAME_NOFOLLOW_ANY`, both by exact
  leaf path. Ordinary rename-overwrite and truncating direct writes are absent. These fail
  closed:
  - a symlink, directory, device, or other non-regular leaf;
  - a symlinked path component;
  - an observed identity or type race;
  - an unsupported extension;
  - cross-device staging;
  - a volume without exclusive or swap renaming;
  - a case, normalization, or firmlink alias of an existing leaf or of the parent folder;
  - an item-replacement directory that is the chosen folder or its direct child, or that lies
    inside the chosen folder outside the app-private root (D5 step 1, owner decision
    2026-09-30).

  *(Reopened 2026-09-29; re-proven by PR E2.)*
- [x] Overwrite postflight proves the leaf holds the writer bytes and the staged name holds
  the exact displaced panel-approved identity before cleanup. A mismatch reverses only
  after an exact two-name proof. Otherwise both identities remain, the exact leaf and
  item-replacement paths are reported, and success is impossible. *(Reopened 2026-09-29;
  re-proven by PR E2.)*
- [x] Source collisions reuse the authoritative App ownership inventory from Save Copy
  and mutations, including detached/recovery/indeterminate aliases; hard links and
  case/canonical aliases are rejected. *(Reopened 2026-09-29; PR E2 moved the adapter's
  identity, canonical spelling, and case sensitivity to leaf-path metadata. The hosted
  tests run outside the sandbox, as PR E's did.)* Precisely:
  - the destination spelling is proven kernel-canonical before ownership runs (`F_GETPATH`
    of an existing leaf; `getattrlist(ATTR_CMN_FULLPATH)` of a new leaf's parent), so any
    case, normalization, or firmlink alias of the selected path is refused as
    `destinationAlias`;
  - the inventory then matches hard links by `st_dev`/`st_ino` and locations by full-path
    alias keys (NFC, plus case folding on a case-insensitive volume) against that canonical
    spelling;
  - owned URLs are compared in the spelling the App retained: descriptor-derived for
    anchored locations, and as stored for context-only URLs.
- [x] The writer creates only its selected leaf and one staged file in its accepted
  item-replacement directory. A clean outcome proves the staged file and returned directory
  absent. This does **not** promise that Foundation creates no shared ancestor: unsandboxed
  exports to an external APFS volume root can leave `.TemporaryItems/folders.<uid>/` before
  containment refuses the returned directory. Metadata-only before/after observations cover
  those two paths and the selected-folder descendants leading to an injected app-private root.
  A new, replaced, or relevant unobservable ancestor produces `.indeterminate` with its exact
  `unprovenDirectoryURLs`, even after the operation-private directory was removed or the
  Foundation provider threw. Those ancestors are never deleted by the writer. Existing ancestors
  whose identities remain unchanged are preserved without being attributed to this operation.
  No delivered sibling, recovery journal, bookmark, retry/fallback destination, or second
  artifact is intentionally created. The existing temporary-folder namespace test and fake
  container test prove their fixture-specific no-extra-entry observations; actual sandbox
  save-panel grants and external-volume no-extra-entry observations remain open under the
  leaf-grant bullet above. *(Review correction, 2026-10-01.)*
- [x] Namespace/cleanup uncertainty is reported with the exact leaf and item-replacement
  paths, and is never called an identity-atomic non-commit or a clean success. If the
  user's displaced original is left inside the app container, the report says so.
  *(Reopened 2026-09-29; re-proven by PR E2 at the writer level. PR F owns the
  user-visible wording.)*
- [x] Write failure/uncertainty is reported as failure and cannot be presented as a
  complete artifact. *(Reopened 2026-09-29; re-proven by PR E2 at the writer level.)*
- PR E2 evidence (leaf-path writer, 2026-09-30; `swift test --package-path
  Packages/WorkspaceKit` and the hosted `ExportDestinationOwnershipAppTests`). The writer
  (`ExportArtifactWriter` in WorkspaceKit) proves the leaf with
  `fstatat(AT_FDCWD, …, AT_SYMLINK_NOFOLLOW_ANY)` of the parent path and the exact leaf path,
  opens an existing leaf with `O_NOFOLLOW_ANY` only to require its `F_GETPATH` spelling to
  equal the selected spelling (for a new leaf, the parent's `getattrlist(ATTR_CMN_FULLPATH)`
  spelling must equal the selected parent spelling), stages one file in Foundation's
  item-replacement directory (compared with the chosen folder by identity before any other
  use, never opened, canonical `getattrlist` spelling, same `st_dev`, containment per D5
  step 1), and publishes with `renameatx_np(AT_FDCWD, staged, AT_FDCWD, leaf, …)`. Removals
  use `unlinkat(…, AT_SYMLINK_NOFOLLOW_ANY)`. It returns `.committed` only
  when the leaf holds the staged identity and byte count, any displaced original was unlinked,
  and the staged name and the directory are proven absent; `.notCommitted` only when nothing
  was published (or a swap was provably reversed) and no operation entry remains; otherwise
  `.indeterminate` with the exact selected URL, staged-file URL, item-replacement directory
  URL, unproven shared-ancestor URLs, residue contents (displaced original, writer bytes, or unknown), and
  `residueIsInPurgeableTemporaryFolder`.
  - Publication: `testNewLeafPublishesWithExclusiveRenameAndRemovesStaging`,
    `testConfirmedOverwriteSwapsExactIdentityAndKeepsTheDisplacedMode` (an outside hard link
    keeps the displaced bytes; Q3 mode kept), `testNewLeafModeIsTheUmaskDefault` (Q3),
    `testOverwriteKeepsPermissionBitsButNeverSpecialBits` (Q3 hardening: `04755` becomes
    `0755`, `0640` stays `0640`),
    `testInspectDestinationReportsNewLeafAndPanelApprovedIdentity`,
    `testLeafInspectionComesFromLeafPathMetadata`,
    `testUbiquitousDestinationPublishesInsideFileCoordination` (Q1, injectable ubiquity; a
    coordination failure publishes nothing). Q1's real `NSFileCoordinator` branches, not
    mocked:
    - `testCancelledCoordinationPublishesNothing`: the coordination error branch, via a
      cancelled coordinator; deterministic.
    - `testCoordinatedMoveWhileWaitingIsRefusedByTheAccessorURL`: a byte-exact accessor-URL
      mismatch from a second real coordinated writer that moves the leaf. It releases that
      writer after a timed margin, because no signal is observable that shows the export is
      waiting.
  - Refusal matrix: `testSymbolicLinkLeafIsRefusedForBothDispositions`,
    `testSymbolicLinkPathComponentIsRefused` (final and intermediate component),
    `testSymlinkedComponentAtThePublishBoundaryIsRefusedByRenameNoFollowAny` (the kernel
    flag itself, after the re-proof passed), `testDirectoryAndFIFOLeavesAreRefusedAsNonRegular`
    (device nodes cannot be created unprivileged; the FIFO exercises the same refusal),
    `testUnsupportedExtensionsAndInvalidURLsWriteNothing`,
    `testDispositionMismatchesAreRefusedBeforeStaging`,
    `testCaseAndNormalizationAliasOfExistingLeafIsRefused`,
    `testFirmlinkCaseOrNormalizationSpellingOfTheParentIsRefused` (a new leaf's parent,
    proven by `getattrlist` without an open),
    `testSymlinkSwappedInBeforeTheParentSpellingObservationIsRefused` (spelling, identity, and
    type come from one observation), `testPathAttributeReplyParsingIsStrict`,
    `testMissingOrUnsearchableParentFailsBeforeAnyWrite`,
    `testUnsupportedVolumeCapabilitiesFailClosedBeforeStaging` (keys read from the parent URL
    for a new leaf, the leaf for an overwrite), `testRealVolumeKeysReportBothRenameSemanticsOnTheTestVolume`,
    `testCrossDeviceItemReplacementDirectoryIsRefusedWithoutCopyFallback` (a real devfs/data
    volume pair), `testItemReplacementDirectoryInsideTheChosenFolderIsRefusedAndRemoved`
    (Foundation's sibling fallback, a deeper directory, and the chosen folder itself, which is
    never removed, opened, or read except by metadata),
    `testStagingInsideTheChosenFolderOutsideRuleBIsRefused` (a chosen folder equal to or inside
    the private root, a root reachable only through a symlink, a directory outside the root),
    `testDirectChildAndTheChosenFolderItselfAreRefusedWithoutOpeningIt`,
    `testNilPrivateRootKeepsRefusingStagingInsideTheChosenFolder`,
    `testPrivateRootMustExistBeforeStagingBegins` (proven before Foundation is asked),
    `testIdentityAndTypeRacesBeforePublicationFailClosedWithoutTouchingRacer`
    (including a replaced parent directory),
    `testRaceAtTheFinalPublishBoundaryNeverOverwritesTheRacerOrClaimsSuccess`,
    `testOwnershipRefusalWritesNothingAndReceivesTheLeafInspection`,
    `testCancelledOperationWritesNothing`.
  - Fault injection (staging create/write/chmod/fsync, publish, postflight, two-name proof,
    reverse swap, reversal proof, displaced unlink, staged unlink, removal proof, `rmdir`):
    `testStagingCreateWriteChmodAndSyncFailuresLeaveTheDestinationUntouched`,
    `testRealStagingCreateDenialIsNotPermittedWithoutFallback` (real `EACCES`),
    `testPublishFailuresRemoveStagingAndLeaveTheDestinationUnchanged`,
    `testPostflightMismatchReversesTheSwapOnlyAfterAnExactTwoNameProof`,
    `testNewLeafPostflightMismatchIsIndeterminateAndNeverUnlinksTheLeafByPath`,
    `testReverseSwapFailurePreservesBothIdentitiesAndReportsExactPaths`,
    `testDisplacedUnlinkFailureReportsTheOriginalInThePurgeableTemporaryFolder`,
    `testStagingDirectoryRemovalFailureIsNeverSuccessOrACleanNonCommit`,
    `testUnpublishedStagedFileThatCannotBeRemovedIsReportedExactly`,
    `testCommittedNewLeafRequiresTheStagedNameProvenAbsent`,
    `testRemovalNeverFollowsASymlinkedStagingComponent` (the staged unlink and the `rmdir`),
    `testStagingDirectoryThatCannotBeCanonicalizedIsRemovedOrReported`,
    `testRefusedStagingDirectoryThatCannotBeRemovedIsReportedExactly`,
    `testUnobservableReturnedDirectoryIsReportedNotCalledAbsent`,
    `testUnavailableItemReplacementDirectoryFailsClosedWithoutFallback` (only proven absence is
    a clean non-commit), `testParentSpellingObservationFailureAtPreflightWritesNothing`,
    `testParentSpellingObservationFailureAtTheReproofPublishesNothing`,
    `testPrivateRootObservationFailureLeavesOnlyRuleA`.
  - Namespace and lifetime: `testNoEntryOtherThanTheLeafIsEverCreatedInTheChosenFolder`
    (directory snapshots at every boundary; exactly one staged file, outside the chosen
    folder), `testWriteOnlyParentPublishesWithoutEverOpeningTheChosenFolder`,
    `testFoundationReturnsDistinctStagingDirectoriesOutsideSelectedTemporaryFolderOnSameDevice`,
    `testWriterReleasesEveryDescriptorAfterEachOutcomeKind`,
    `testStagingInsideTheAppPrivateRootIsAcceptedWhenTheChosenFolderIsItsAncestor` (at every
    boundary the fake home folder holds only its prior entries and the leaf).
  - Ownership (hosted `ExportDestinationOwnershipAppTests`; the App adapter
    `App/AppState+ExportDestinationOwnership.swift` re-derives the writer's
    `ExportArtifactLeafInspection` and requires equality, then walks the Save Copy owner
    inventory (hard links by `st_dev`/`st_ino`, locations by full-path alias keys under the
    volume case flag) and the mutation owner URLs; every refusal test first proves an
    unowned control is permitted): all PR E cases, now driven by the leaf inspection —
    `testHardLinkToCachedAnchoredSessionIsRefusedAndNothingIsWritten`,
    `testHardLinkToEveryUnanchoredManagedOwnerIsRefused`,
    `testCaseAliasOfMissingDetachedSessionIsRefused`,
    `testQuarantinedIndeterminateSaveCopyDestinationIsRefused`,
    `testLiveWorkspaceMutationRecoveryCandidateAndItsCaseAliasAreRefused`,
    `testTextRecoveryOriginalAndContextOnlyOwnersAreRefused`,
    `testSubfolderExportCollidingByHardLinkIsRefusedAcrossRootAuthorities`,
    `testSubfolderCaseAliasOfOwnedMissingFileIsRefusedByFullPathComparison`,
    `testRecoveryStoreLoadFailureRefusesEveryExportDestination`,
    `testUnownedDestinationCommitsAndOnlyAFileLessSourceIsExempt`,
    `testDisagreeingWriterInspectionIsRefused` — plus
    `testWriteOnlyParentNeedsNoParentHandleForOwnership` (the retired parent-anchored
    inspection throws there; the leaf-path adapter refuses the hard link and commits the
    control), `testFirmlinkSpellingOfAnOwnedMissingDestinationIsRefused` (refused as an alias
    before ownership; the canonical spelling is refused by the inventory), and
    `testExportAppPrivateRootValidatesInjectedContainerIDAndHomeSuffix`.
- PR E evidence (historical: the parent-anchored writer, retired for panel destinations by
  the 2026-09-29 D5 amendment; its hosted App ownership tests ran outside the sandbox and
  used parent-descriptor inspection). Writer level, headless: `ExportArtifactWriter` in WorkspaceKit reuses the
  audited `WorkspaceAnchoredFileSystem` staging/`RENAME_EXCL`/`RENAME_SWAP`/postflight/
  reverse-swap/cleanup primitives and returns `.committed` only when the writer bytes are
  durable and the staging name is re-proven empty; every other result is `.notCommitted`
  (destination proven in or restored to its pre-operation state, no operation entry left;
  a rollback may have briefly published writer bytes) or `.indeterminate` (exact selected
  URL, typed destination state, exact residue/staging URL, and whether a retained entry
  holds the user's displaced original or the writer's bytes). Publication:
  `testNewLeafPublishesWithExclusiveRenameAndProvesStagingAbsent`,
  `testConfirmedReplacementSwapsExactIdentityWithoutTruncatingDisplacedInode` (an outside
  hard link keeps the displaced bytes), `testInspectDestinationReportsNewLeafAndPanelApprovedIdentity`.
  Refusal matrix: `testSymbolicLinkDestinationIsRefusedForBothDispositions`,
  `testSymbolicLinkInParentPathIsRefused` (`O_NOFOLLOW_ANY` on the literal parent),
  `testDirectoryAndFIFODestinationsAreRefusedAsNonRegular` (device nodes cannot be created
  unprivileged; the FIFO exercises the same non-regular refusal),
  `testUnsupportedExtensionsAndInvalidURLsWriteNothing`,
  `testDispositionMismatchesAreRefusedBeforeStaging`,
  `testCaseAndNormalizationAliasOfExistingLeafIsRefused`,
  `testMissingParentAuthorityFailsBeforeAnyWrite`,
  `testDeniedStagingCreateIsNotCommittedWithoutAnyFallbackWrite` (real `EACCES` and
  `EPERM` staging denials),
  `testUnsupportedVolumeSemanticsFailClosedBeforeStaging`,
  `testProbedVolumeCapabilitiesReportExclusiveAndExchangeRenameOnTestVolume`,
  `testIdentityAndTypeRacesAfterInspectionFailClosedWithoutTouchingRacer`,
  `testRaceAtFinalPublishBoundaryNeverOverwritesRacerOrClaimsSuccess`,
  `testOwnershipRefusalWritesNothingAndReceivesTheWritersInspection`,
  `testCancelledOperationWritesNothing`. Fault injection at staging create/write/fsync,
  publish, postflight read, parent sync, reverse swap, and cleanup:
  `testStagingCreateWriteAndSyncFailuresProveDestinationUntouched`,
  `testPublishFailuresRemoveStagingAndLeaveDestinationUnchanged`,
  `testPostflightReadAndParentSyncFailuresRollBackToProvenNonCommit`,
  `testReverseSwapFailurePreservesBothIdentitiesAndReportsExactPaths`,
  `testReverseSwapSyncFailureReportsRestoredDestinationAndRetainedWriterStaging`,
  `testCreatedDestinationRollbackFailureIsIndeterminateAndKeepsWriterBytes`,
  `testDisplacedCleanupFailuresAreIndeterminateEvenThoughWriterBytesArePublished`,
  `testUnexpectedDisplacedEntryPreventsReverseSwapAndPreservesBothIdentities`. Lifetime:
  `testCommittedNewLeafRequiresStagingNameProvenAbsent`,
  `testWriterReleasesEveryDescriptorAfterEachOutcomeKind`. Ownership (hosted
  `ExportDestinationOwnershipAppTests`, App adapter
  `App/AppState+ExportDestinationOwnership.swift` over the Save Copy and mutation
  inventories; every refusal test first proves an unowned control is permitted):
  current/cached anchored and hard link `testHardLinkToCachedAnchoredSessionIsRefusedAndNothingIsWritten`;
  cached/retired/editor-bound unanchored hard links `testHardLinkToEveryUnanchoredManagedOwnerIsRefused`;
  detached case alias `testCaseAliasOfMissingDetachedSessionIsRefused`; quarantined
  indeterminate Save Copy `testQuarantinedIndeterminateSaveCopyDestinationIsRefused`; live
  `workspaceMutationRecoveries` candidate and its case alias
  `testLiveWorkspaceMutationRecoveryCandidateAndItsCaseAliasAreRefused`; pending text-recovery
  `originalURL` plus context-only URL owners (`lastKnownDiskHashes`, `detachedSessionURLs`)
  `testTextRecoveryOriginalAndContextOnlyOwnersAreRefused`; export into a workspace subfolder,
  whose parent is a different root authority, colliding by hard link
  `testSubfolderExportCollidingByHardLinkIsRefusedAcrossRootAuthorities` and by case alias
  through the Save Copy full-path comparison
  `testSubfolderCaseAliasOfOwnedMissingFileIsRefusedByFullPathComparison`; recovery-store
  load failure `testRecoveryStoreLoadFailureRefusesEveryExportDestination`; source exemption
  only for a file-less source `testUnownedDestinationCommitsAndOnlyAFileLessSourceIsExempt`;
  writer/App inspection disagreement `testDisagreeingWriterInspectionIsRefused`. Not
  separately exercised: a restored (promoted) text-recovery session, whose unavailable proof
  makes the inventory refuse every export destination, as it refuses Save Copy.
- Historical, superseded by the 2026-09-29 amendment. Sibling bullet left unchecked for owner reading:
  `testAtMostOneOperationSiblingExistsAtEveryObservedBoundary` proves at most one operation
  sibling at every observed boundary of a successful replacement or new leaf, and success
  proves both names clear. The audited cleanup, however, renames the displaced inode from
  the staging name to a second random `.plainsong-cleanup-*` name before unlinking it, and
  an uncertain cleanup can leave that second name holding the user's original (reported
  exactly, `testDisplacedCleanupFailuresAreIndeterminateEvenThoughWriterBytesArePublished`).
  Checking this bullet requires the owner to accept that the cleanup name is the same
  staging file under a second randomized name.
- Resolved 2026-09-29: PR F's owner smoke answered the Powerbox question. A real
  save-panel leaf grant does **not** authorize parent-anchored sibling staging:
  `~/Desktop` and `~/Documents` were refused with `parentAuthorityUnavailable` and nothing
  was written. D5 is amended to item-replacement staging plus exact-leaf publication (see
  the D5 amendment evidence). The fresh-panel-URL/cancel/stale bullet remains PR F work.

### E7 — App / File-menu UX and side-effect isolation

- [x] HTML: the actual File menu contains one Export as HTML… item after Save,
  with no top-level Export menu and an empty key equivalent. Availability requires a
  file-backed `.md`/`.mdx` and a document window. The declaration places the command
  after `.importExport`; the native menu test also checks before Print when present.
- [ ] PDF/Print command availability and menu smoke (PR G).
- [x] HTML: fresh save panels are configured for `.html`, sanitized title/basename defaults,
  directory creation, and accessibility. Destination/presentation seams prove cancellation
  and document isolation; real sheet/Powerbox/bookmark lifetime acceptance stays under E6.
- [ ] PDF panel defaults (PR G), and owner verification of the real HTML panel (E6).
- [x] HTML: progress/Cancel, render/MDX/resource errors, placeholder counts, every writer
  failure group, and indeterminate paths have accessible word/symbol feedback.
- [ ] PDF failure/Print cancellation feedback (PR G); keyboard/VoiceOver owner smoke.
- [x] HTML success/cancel/failure/indeterminate leaves text, selection, editor/visible-preview
  scroll/DOM/theme, dirty/saved baseline, identity, recents, tree and recovery state unchanged.
- [ ] PDF/Print side-effect isolation (PR G).
- Evidence: `ExportHTMLCommandAppTests.testAvailabilityRequiresMarkdownOrMDXAndADocumentWindow`,
  `testFileMenuContainsExportInTheImportExportSlotWithoutAShortcut`,
  `testSettingsAndAboutCannotBecomeExportSheetParents`,
  `testConfiguredFreshSavePanelsReadRequestDefaultsAndCancelWithoutRetainingDestination`,
  `testFilenameSanitizerRemovesLeadingDotsAndBoundsUTF8WithoutSplittingCharacters`,
  `testProgressResultAndErrorAreAnnouncedOnceAndCancelIsSilent`,
  `testUntitledDocumentIsRefusedBeforeAnyPanel`,
  `testPanelDefaultsSanitizeTitlesAndFallBackForInvalidOrEmptyFrontmatter`,
  `testEveryInvocationRequiresAFreshPanelResultAndNeverReusesACancelledDestination`,
  `testUnavailableOwnershipAndRecoveryLoadFailureRefuseBeforeThePanel`,
  `testInjectedWriterOutcomesTravelThroughTheCommandWithoutPublishing`, and
  `testSuccessCancelFailureAndIndeterminateLeaveEditorPreviewAndDocumentStateUnchanged`.
  `testExportPanelFocusChangesDoNotFlushTheDirtySavedBaseline` proves the export sheet
  does not trigger a focus-loss Save and normal focus autosave still runs afterwards.
  `ExportHTMLFeedbackAppTests` covers every writer failure group and its accessibility
  label, cancellation/supersession, every destination/residue state combination with exact
  paths, purgeable displaced-original recovery text, and the safe DEBUG preview.
  `ExportHTMLOmissionCountTests` proves authored lookalikes cannot inflate the count.
  The Phase A `AppState+Autosave.swift` change only moved `SessionBackgroundTask`; it is
  no longer in the main diff after merging E2. Phase B does not suspend timer/explicit/
  termination autosave. Its focus-notification guard applies only while choosing an
  export destination: this is the narrow export-panel exception to agent.md §4 autosave
  on window resign; ordinary focus autosave resumes afterwards.

### E8 — Format, content, theme, and layout matrix

- [x] HTML: named `export-f-markdown.md`, `export-f-mdx.mdx`, and `math.md` cover
  frontmatter, GFM, KaTeX, highlighted code, Mermaid, task checkboxes, eligible/missing/
  remote images, and MDX placeholders.
- [x] HTML: Source-only, source+preview and Experimental WYSIWYG have content-equivalent
  static HTML for each deterministic snapshot/resource/theme combination.
- [ ] PDF/Print content/theme matrix and the distinct D4 pagination contracts (PR G).
- [x] HTML: light, dark and resolved-system themes are frozen at invocation without
  mutating the visible preview.
- [ ] PDF/Print theme matrix (PR G).
- [x] HTML: render errors and MDX stale-last-good DOM fail rather than exporting old content.
- Evidence: `testNamedMarkdownAndMDXFixturesAreEquivalentAcrossLayoutsAndFreezeAllThemes`
  runs 18 product-command cases (two formats × three layouts × three themes), comparing
  content with only generated Mermaid numeric IDs normalized; it asserts placeholders,
  embedded images, task inputs, tables, highlighted fences, math/fonts and SVG.
  `testMathFixtureExportsThroughTheProductCommand` uses the real `Fixtures/math.md`.
  `testThemeChangesWhilePanelIsOpenDoNotChangeTheInvocationTheme` proves the frozen theme.
  `testMDXSyntaxErrorFailsWithoutWriting` and PreviewKit's
  `testMDXSyntaxErrorFailsInsteadOfExportingLastGoodDOM` prove failure, never prior content.

### E9 — Accessibility, performance, security, and regression

- [x] HTML: identifier constants are distinct; notice/progress labels cover every mapped
  error group. The configured AppKit save panel exposes its native `save-panel`
  identifier and receives the requested spoken label; a custom panel identifier is not claimed.
  SwiftUI-to-NSMenuItem/banner identifier delivery remains owner UI acceptance.
  Named evidence:
  `testStopReasonsHaveDistinctAccessibleMessagesAndStableControls`,
  `testEveryWriterFailureMapsToAnActionableAccessibleGroup`, and
  `testIndeterminateStatesAndEveryResidueReportRecoveryPathsWithoutClaimingSuccess`.
- [ ] Keyboard-only HTML acceptance; PDF/Print accessibility and keyboard flows (owner/PR G).
- [ ] Measure the production offscreen path with a large document, code-heavy/KaTeX/
  Mermaid fixture, and many bounded raster assets in Debug and Release before freezing
  any export-specific wall-clock or memory budget.
- [ ] Export work never enters the editor keystroke path; the existing < 16 ms typing
  budget remains green while export is active.
- [ ] Existing preview protocol, asset containment, MDX sanitizer, theme, render,
  scroll-sync, Save/Save Copy, and workspace mutation/recovery suites remain green.
- [x] Dependency manifests are unchanged.
- PR E evidence: `git diff origin/main -- '*Package.swift' '*Package.resolved'
  'preview-src/package*.json' project.yml` is empty for the writer PR. The full
  WorkspaceKit suite (Save/Save Copy/mutation/recovery write primitives) and the hosted
  App Save Copy/mutation suites stay green with the writer and adapter; the remaining
  preview/render/scroll suites and measured evidence stay open for PR G.
- PR E2 evidence: `git diff 1c3a4d7 -- '*Package.swift' '*Package.resolved'
  'preview-src/package*.json' project.yml` is empty. The full WorkspaceKit suite and the
  hosted `ExportDestinationOwnershipAppTests`, `AppStateTests`,
  `AppStateWorkspaceDataIntegrityTests`, `AppStateSessionStateCleanupTests`, and
  `WorkspaceMutation{Operation,Text}RecoveryStoreTests` stay green with the leaf-path writer,
  the restored pre-PR-E write primitive, and the extracted Save Copy owner walk.

### PR F Phase B verification — 2026-10-01

- PreviewKit: 71 tests, zero failures, including the new interceptor and two omission tests.
- WorkspaceKit: 351 tests, zero failures; writer execution/authority are unchanged.
  The only WorkspaceKit addition is public construction of the immutable uncertainty
  result for the DEBUG wording preview; it grants no filesystem authority.
- Hosted App slices after formatting: 410 tests, one expected skip, zero failures.
  `ExportHTMLCommandAppTests` 24; `ExportHTMLFeedbackAppTests` 5;
  App `ExportHTMLOfflineTests` 1; `ExportDestinationOwnershipAppTests` 14;
  `AppStateTests` 176 (one case-sensitive-volume skip on this case-insensitive volume);
  `AppStateWorkspaceDataIntegrityTests` 129; `AppStateSessionStateCleanupTests` 6;
  `WorkspaceMutationOperationRecoveryStoreTests` 46;
  `WorkspaceMutationTextRecoveryStoreTests` 9.
- `Scripts/check-export-sandbox-root.sh` passes with the production default root, nil-root
  refusal, no unauthorized outside write, and no surviving operation paths.
- Preview JS: `npm run typecheck` passes; `npm test` passes 127 tests in 16 files.
- Pinned `make lint`: exit 0, 310 warnings, zero serious violations.
- Locked `make build` passes; `git diff --check` passes.
- No production dependency or bridge change; preview source and committed bundle remain
  byte-unchanged. `project.yml` only adds test fixture resources.
- The three E9 probes compile and skip without opt-in (three skips, zero failures).
  Final locked idle checks found load 35.84 (Debug) and 35.21 (Release); both exited 75
  without measuring. Exact commands and pending items are recorded in `docs/perf-log.md`.
- E9 probes are opt-in and run last under the common lock and idle check. Debug/Release
  export/RSS, active-export typing and 64 MiB synchronous writer are pending an idle
  machine. Real iCloud evicted-leaf/coordination timing, physical-input evidence,
  keyboard-only acceptance and the E6 Powerbox cases remain owner work. No budget is frozen.

### PR F review follow-up — 2026-10-02

- PreviewKit: 71 tests; WorkspaceKit: 351 tests; zero failures and no skips.
- Locked targeted hosted run: 54 App tests, zero failures and no skips:
  `ExportHTMLCommandAppTests` 31, `ExportHTMLFeedbackAppTests` 5,
  App `ExportHTMLOfflineTests` 1, `ExportDestinationOwnershipAppTests` 14,
  and `MenuBarStateTests` 3. The seven new command cases verify availability/window
  refresh, auxiliary-window exclusion, actual configured fresh panels, the native File
  menu and empty key equivalent, bounded Unicode filenames, and spoken transitions.
- E4's App proxy data store is installed before controller construction. The unblocked
  live positive control uses the same factory for its data store and records the
  `.invalid` host. The written file is reopened without the export blocker; both export
  and standalone reopen issue zero HTTP(S) requests. PreviewKit's interceptor is unchanged.
- E8's existing 18-case matrix now forces `NSApp.appearance` to `.darkAqua` and restores
  the previous appearance afterwards, so resolved-system dark is exercised explicitly.
- ONE correctness-only opt-in smoke of each E9 probe body passed under the shared lock
  in Debug (3 tests, zero failures/skips): production export commits one sample each of
  `large-1mb.md` and `export-f-heavy.md` with 24 raster assets; the 64 MiB writer commits
  one sample; the typing body executes the native insertion and public-view update,
  then confirms the edit fences publication. All fixtures use canonical roots and
  anchored session bindings. No time/memory sample is reported as E9 evidence and the
  typing budget assertion is bypassed only by `PLAINSONG_EXPORT_E9_SMOKE=1`.
  Formal Debug/Release measurements remain **pending idle-machine run**.
- Reproduce the combined targeted run with `TEST_RUNNER_PLAINSONG_RUN_EXPORT_E9=1`
  and `TEST_RUNNER_PLAINSONG_EXPORT_E9_SMOKE=1` before
  `Scripts/run-export-html-hosted-tests.sh`, adding `-only-testing:PlainsongTests/MenuBarStateTests`,
  `-only-testing:PerformanceTests/ExportHTMLPerformanceTests`, and
  `-only-testing:PerformanceTests/AppBackedEditorPerformanceTests/testTypingDuringActiveHTMLExportStaysWithinTheExistingFrameBudget`.
  Set `PLAINSONG_XCODEBUILD_LOCK` to the shared machine lock for coordinated runs.
  `Scripts/run-export-html-e9.sh --smoke Debug` also exposes the correctness-only mode;
  normal Debug/Release runs retain the idle check and existing typing assertion.
- `Scripts/check-export-sandbox-root.sh` passes: the production default root admits
  staging, nil root refuses, unauthorized outside publication is denied, and operation
  paths are absent. Locked `make build` passes; `git diff --check` passes.
  Pinned SwiftFormat 0.62.1 `make lint` exits 0 (312 warnings, zero serious).
  Changed feature files contain no session-specific lock/lint paths; no writer, bridge,
  preview source/bundle, dependency manifest or `project.yml` change is added by this review fix.
- Checked-box wording is narrowed to evidence: E7 covers native menu bounds and actual
  panel configuration/cancellation, while E9 covers declared identifiers, mapped labels,
  and the panel's native `save-panel` identifier (AppKit ignores the custom setter).
  Actual SwiftUI identifier delivery to NSMenuItem/banner controls, real sheet/Powerbox
  and bookmark-lifetime acceptance, keyboard navigation and VoiceOver remain owner work.
  Progress start, result and error post `announcementRequested` on the application;
  duplicate filename updates and silent cancellation do not announce again.
- Release test seams remain live, matching repository practice and the Release E9
  destination chooser. E6 owner boxes remain unchecked; no D5 relaxation or off-main
  writer change. The export-panel window-resign autosave exception is recorded under
  E7 and in the Phase B Decision Log; `agent.md` is unchanged. Main's Decision Log rows
  are untouched; only the feature's Phase A/Phase B rows are updated.

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

### PR E2 review follow-up evidence — 2026-10-01

- `testFoundationScaffoldingIsReportedAfterTheReturnedDirectoryIsRemoved` covers absent,
  partly pre-existing, and fully pre-existing `.TemporaryItems/folders.<uid>` ancestors;
  `testFoundationScaffoldingIsReportedEvenWhenTheProviderThrows` and
  `testUnobservableFoundationScaffoldingBelowTheReturnedPathIsReported` cover acquisition
  failure and uncertain metadata. `testKnownAbsentScaffoldingThatBecomesUnobservableAfterProviderThrowsIsReported`
  distinguishes known absence from denied metadata; the outside-staging control
  `testUnobservableUnrelatedScaffoldingDoesNotRejectOutsideStaging` guards against rejecting
  every leaf grant when unrelated metadata is denied. Only the returned identity-checked empty
  directory is removed.
  `testPrivateRootMustExistBeforeStagingBegins` now reports the exact retained `Library` →
  `Data` ancestor chain when its provider creates a previously absent root.
- Root guards: `testPrivateRootObservationFailureLeavesOnlyRuleA` (stat failure),
  `testPrivateRootGetattrlistFailureRefusesRuleBWithoutPublication`,
  `testNonDirectoryPrivateRootRefusesRuleBBeforeGetattrlist`,
  `testPrivateRootTypeOrIdentityChangeBeforeGetattrlistRefusesRuleB`, and
  `testPrivateRootFirmlinkSpellingUsesKernelCanonicalContainment`, alongside the existing
  nil-root/symlink/containment controls. Injected input-shape testing is explicitly named
  `testExportAppPrivateRootValidatesInjectedContainerIDAndHomeSuffix`.
- Real app-sandbox process: run `Scripts/check-export-sandbox-root.sh`. It compiles the same
  production `AppState.exportAppPrivateRoot()` source into a helper signed with Plainsong's
  sandbox entitlements, without injecting its environment or home. On macOS 27 / Xcode 27:
  `APP_SANDBOX_CONTAINER_ID=app.plainsong.export-root-probe`; `NSHomeDirectory()` was
  `/Users/davis._.su/Library/Containers/app.plainsong.export-root-probe/Data`; default root was
  that non-nil Data directory. The helper's unique `/private/tmp` write was denied and absent.
  With the actual root, production writer + Foundation provider reached one root canonical
  observation, one staged-file create and one publication attempt for a unique leaf in the real
  user's home. Publication was correctly denied with `EPERM` because no Powerbox grant was
  supplied; cleanup proved the staged file/directory absent. A nil-root control refused at
  containment with zero staged creates/publications. This proves runtime acquisition and rule
  (b) supply, **not** a successful `NSSavePanel` grant. PR F's save-panel owner smoke for
  `~/x.html`, accented folders and an external APFS root remains open. The scaffolding tests
  simulate Foundation's observed external-root layout; no external volume was written here.
