# Custom Themes and User CSS — Design Draft

> **Status: owner decisions accepted 2026-10-29.** Token colors only, unknown fields
> reject the whole schema v1 file, colors only (no fonts), and Mermaid colors stay a
> follow-up. The decision record is `docs/decisions/2026-10-29-editor-custom-themes.md`.
> PR B implements editor themes (T1-T3). Preview tokens in the same file are validated
> and stored, but `setThemeTokens` and `PROTOCOL_VERSION` 9 stay deferred.

## 1. Problem

Users want their editor and preview to match their blog. Two different features hide
behind "custom themes", with very different risk:

1. **Token themes** — choosing colors for a fixed set of named slots.
2. **User CSS** — arbitrary stylesheets applied to the preview.

This draft proposes shipping (1) and keeping (2) deferred behind its own gate.

## 2. Current state (code verified)

| Surface | Where | Today |
|---|---|---|
| Editor theme choice | `MarkdownEditorTheme` (`standard`, `graphite`) in `Packages/EditorKit/Sources/EditorKit/MarkdownSyntaxTheme.swift`; persisted by `PlainsongPreferences` (`Keys.editorTheme`) | enum, two cases |
| Editor colors | `MarkdownSyntaxTheme`: 14 `NSColor` slots (text, muted, heading, link, code, code background, frontmatter + background, list marker, five TSX slots) | dynamic system colors |
| Editor chrome colors | text view background, selection, caret, gutter | system colors, not in the theme |
| Preview theme | `PlainsongPreferences.PreviewTheme` (`system`/`light`/`dark`) → `setTheme` bridge message (`SetThemePayload{theme, allowRemoteImages}`) → `:root[data-theme]` in `preview-src/src/styles/base.css` | three fixed palettes |
| Preview tokens | `--preview-*` (fg, bg, muted, accent, border, separator, stripe, code-bg, caution ×3) and `--hl-*` (keyword, string, number, comment, function, type, attribute, declaration, preprocessor, link, addition/deletion bg) | defined per palette in `base.css` |
| Mermaid | theme baked into SVG; a theme change re-renders (§7.2) | light/dark only |
| Export | E3: system/light/dark freeze the resolved built-in styling | built-ins only |
| CSP | `style-src 'self' 'unsafe-inline'; img-src asset: data: https:; font-src 'self'` (static, `index.html`) | — |

## 3. Proposal: token themes (v1)

### 3.1 File format

One JSON file defines both editor and preview colors:

```json
{
  "schemaVersion": 1,
  "id": "solarized-ink",
  "name": "Solarized Ink",
  "light": { "editor": { "text": "#24292F", "heading": "#0B4F9C" },
             "preview": { "fg": "#24292F", "bg": "#FFFFFF", "hl-keyword": "#9B2393" } },
  "dark":  { "editor": { }, "preview": { } }
}
```

- `editor` keys are the `MarkdownSyntaxTheme` slots plus four new chrome slots:
  `background`, `selection`, `caret`, `gutter`.
- `preview` keys are the existing token names without the `--preview-`/`--` prefix.
- Every key is optional; a missing key inherits the matching built-in (`standard` /
  bundled light or dark). A theme may omit `dark` entirely, which then follows the
  built-in dark palette.

### 3.2 Validation (strict, reject the whole file)

- ≤ 64 KiB, UTF-8, a closed walk of the JSON object rather than `JSONDecoder`;
  `schemaVersion` must be `1`. `JSONDecoder` would drop unknown fields, which this
  schema must reject. Duplicate keys, and nesting deeper than a palette, are rejected
  before `JSONSerialization`.
- Unknown keys reject [owner: strict for v1, so typos surface; a later schema can relax].
- Values: `#RRGGBB` or `#RRGGBBAA` only. No names, `rgb()`, `var()` or other CSS text,
  so preview values can never carry CSS syntax. `text`, `caret`, and `background` must
  be opaque (`#RRGGBB`, or `#RRGGBBAA` whose alpha is `FF`).
- `id`: `[a-z0-9-]{1,64}`, must not collide with a built-in. `name` is trimmed,
  NFC-normalized, 1–128 Unicode scalars, and cannot contain control, format, or
  line-break characters or start with a combining mark. Imported themes are listed in
  their own picker section. The picker shows `name (id)` when that name matches a
  built-in display name, or another imported theme, without regard to case.
- Contrast is **warned, not enforced** (gate T7): Settings will show a notice when
  text/background or code text/code background falls below 4.5:1. Until that warning
  exists, an editor theme resolves to the built-in palette while Increase Contrast is on.

Validation is a pure MarkdownCore function with table tests; App owns file I/O.

### 3.3 Storage and import

- Settings › Editor gains **Import Theme…** (`NSOpenPanel`, `.json`). The validated file
  is copied into the sandbox container's `Application Support/Plainsong/Themes/<id>.json`.
  No bookmark is kept; the original file is never read again.
- Re-importing the same `id` asks to replace. **Reveal in Finder** and **Remove** act on
  the container copy (Remove moves it to the Trash, agent.md §5).
- At launch, an unreadable or invalid stored theme falls back to the built-in with a
  non-modal notice; the preference keeps the id so a fixed file is picked up again.
- No live file watching in v1.

### 3.4 Applying it

- **Editor:** `MarkdownSyntaxTheme` gains the chrome slots; a resolved theme supplies
  `NSColor(name:dynamicProvider:)` values so appearance switches need no reload. Applying
  equal attributes must stay a no-op (agent.md §6.2) so a theme change does not re-typeset
  more than once.
- **Preview:** a new bridge message `setThemeTokens {light, dark}` carries the validated
  maps; JS writes them as custom properties on a dedicated `<style id="theme-tokens">`
  scoped to `:root[data-theme=…]`. Built-in themes send empty maps. This is a bridge
  change: `BridgeMessage.swift` + `bridge.ts` + `PROTOCOL_VERSION` 9 + `make
  preview-bundle` in one commit (agent.md §17 rule 5).
- **Mermaid:** v1 keeps light/dark Mermaid themes chosen by the effective appearance;
  token-driven Mermaid `themeVariables` is a follow-up.
- **Export:** HTML/PDF freeze the resolved token values, like built-ins (export-gates E3
  amendment).

### 3.5 Why tokens are safe

Values are validated colors, written by Plainsong's own code into custom properties.
There is no selector, `url()`, `@import`, `content` or layout control in user hands, so
token themes add no tracking, spoofing or layout risk.

## 4. User CSS (deferred, v2)

Arbitrary CSS from the internet is a real attack surface even under the current CSP:

| Risk | Detail |
|---|---|
| Tracking | `img-src` allows `https:` statically; the "Allow Remote Images" switch is enforced in JS on `<img>` only. A CSS `background: url(https://…)` would bypass it. |
| Spoofing | Selectors can hide content, fake the MDX error banner or stale indicator, or use `content:` to show text that is not in the source. |
| Breaking features | Hiding `[data-line]` anchors, transforms or `position: fixed` break scroll sync; heavy selectors and animations hurt the §12 preview budget. |
| Export | Would freeze third-party CSS into published HTML. |

Prerequisites before user CSS is implemented, each its own gate:

1. Tighten the static CSP so `img-src https:` is present only when remote images are on
   (per-load CSP or a pre-render switch), closing the CSS `url()` bypass for everyone.
2. A CSS sanitizer (tokenizer-based, likely a new npm dependency → `docs/decisions/`) that
   rejects `url()`, `@import`, `@font-face`, `image-set`, `position: fixed`, and scopes
   all rules under the preview body.
3. User CSS never applies to export unless the user opts in per export.

## 5. Alternatives considered

| Alternative | Why not |
|---|---|
| Ship user CSS first (Typora-style) | Largest risk surface; bypasses the remote-image privacy switch today (§4) |
| Separate files for editor and preview themes | Two imports for one look; harder to keep light/dark consistent |
| Import VS Code / TextMate themes | Their scopes do not map onto our 14 Markdown slots; partial imports look broken |
| Store themes by bookmark to the user's file | Live editing would be nice, but needs watching and re-validation; copy-on-import is simpler and sandbox-friendly |
| CSS text values in JSON (e.g. `"bg": "var(--x)"`) | Reopens CSS injection through a supposedly data-only file |

## 6. Gates

| Gate | Evidence |
|---|---|
| **T1 schema/validator** | MarkdownCore table tests: every key, every rejection (size, unknown key, bad color, id rules, schema version), inheritance of missing keys |
| **T2 storage/import** | Hosted tests: import copies into the container, replace prompt, Remove to Trash, invalid stored file falls back with a notice |
| **T3 editor apply** | Theme switch and appearance switch recolor without a document reload; no extra re-typeset (equal-attribute skip holds); typing budget unchanged |
| **T4 bridge** | `setThemeTokens` round-trip tests both sides; `PROTOCOL_VERSION` 9; bundle rebuilt |
| **T5 preview apply** | vitest + hosted: tokens apply per appearance, built-ins send empty maps, Mermaid still re-renders on appearance change |
| **T6 export** | HTML/PDF freeze custom token values; E3 tests extended |
| **T7 accessibility** | Contrast warning shown below 4.5:1; Settings controls keyboard/VoiceOver reachable (owner smoke) |
| **T8 docs** | agent.md §11, README, a file in `docs/decisions/`; ship two sample theme files in `docs/themes/` |

## 7. PR plan

- **A** — this spec.
- **B** — T1 + T2 + T3 (editor-only themes; preview keeps built-ins).
- **C** — T4 + T5 + T6 (preview tokens and export).
- **D** — T7 + T8.
- User CSS: a separate spec after §4's prerequisites; the CSP tightening in §4.1 is worth
  doing independently, since it also hardens the remote-image switch.

## 8. Owner decisions

Accepted 2026-10-29. The record is
`docs/decisions/2026-10-29-editor-custom-themes.md`.

- Token themes only for 1.0. User CSS stays deferred.
- Schema v1 rejects the whole file on an unknown field.
- Colors only. Themes do not choose fonts.
- Mermaid colors stay a follow-up, not v1.
