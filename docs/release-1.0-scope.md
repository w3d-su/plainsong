# Release 1.0 Scope (Draft)

> **Status: DRAFT, 2026-10-29; refreshed 2026-11-06 against `main` at `c4c7806` (#238).
> Nothing here is decided until the owner signs off V1–V6 in §1.** This file proposes
> what "1.0" means for each platform and lists the remaining work against the gates that
> already exist. It does not replace those gate documents; each row points at the source
> of truth.

Baseline: macOS `v0.1.0-alpha.5` (build 189, `a210f85`, published 2026-10-28) is an
unsigned public alpha. Since then `main` has added Windows PRs B2 (#224), C (#230),
D1-0 (#236), and D1a (#238); workspace SVG in the preview (#229); editor color theme
import (#234); the block on every remote preview load while Allow Remote Images is off
(#233, which closed R23); and Sparkle 2, off by default (#232, #235). No published build
contains any of them. iOS has a production composition candidate on `main`
(`docs/ios/integration-ledger.md`, 2026-10-26), to which #228 added source chrome, folder
search, Replace All, and HTML/PDF export and print. iOS has no published build.

Tiers used below:

- **Must** — 1.0 does not ship without it.
- **Should** — planned for 1.0; may slip to 1.0.x with an owner decision.
- **Deferred** — explicitly not in 1.0; stays documented as a known limitation.

## 1. Owner decisions needed first

| ID | Question | Proposed default | Why it matters |
|---|---|---|---|
| V1 | Do macOS and iOS ship 1.0 together? | **No.** macOS 1.0 first; iOS follows as its own 1.0 | iOS still has every device gate open; tying them blocks macOS on hardware evidence |
| V2 | Is multi-window (Windows PR C–G) in macOS 1.0? | **Yes, through D2**; native tabs (F), restoration (E) and residency (G) are Should | Since C (#230) each window has its own state, but a user still cannot work in a second window: New Window is not offered, and a second scene refuses file and root opens and closes itself until D2 (agent.md §5). Without D2, 1.0 is single-window |
| V3 | WYSIWYG at 1.0? | **Ships Experimental, off by default** (no promotion) | Promotion needs the `docs/wysiwyg-release-checklist.md` §D.4 gate and a Decision Log entry. Draft #213 prepares it but waits on the owner's Zhuyin/Pinyin dogfood; the last real IME runs predate STTextView 2.4.1 (R9) |
| V4 | Distribution channel | **Direct DMG, Developer ID + notarized**; Mac App Store later | agent.md §15 locks direct distribution first |
| V5 | Updates | **In-app updates are Should**; at minimum a documented manual update path. Sparkle 2 is integrated and off (U1, #232); turning it on needs U2 and U3 (`docs/auto-update-plan.md` §4) | U-D1 (Sparkle 2) and U-D3 (ask on second launch) are adopted (`docs/decisions/2026-10-29-sparkle-auto-update.md`). U-D2 and U-D4–U-D7 are open; U-D6 reverses the 2026-07-02 no-secrets rule. README keeps "no auto-update" until U3 |
| V6 | Version and channel naming | `1.0.0`, with `0.9.x` signed betas before it | `MARKETING_VERSION` is still `0.1.0` (release plan P0.5) |

## 2. macOS 1.0

### Must

| Item | Remaining work | Source of truth |
|---|---|---|
| Developer ID signing + hardened runtime | Buy Apple Developer Program membership; resume P1; confirm `get-task-allow` stays absent | `docs/release-engineering-plan.md` P1 |
| Notarization + stapling | P2 in the release workflow; signed CI path | `docs/release-engineering-plan.md` P2, P4 |
| Independent windows | C (#230, with R22's 16/16 reruns), D1-0 (#236) and D1a (#238) are merged. D1b (#239) and D1c (#240) are in review. D2 is not started; it owns W0 bullets 1–4 (owner smoke), W2 bullets 1–3, W4 bullets 1–2, W6 bullet 8b, W7 bullets 1–5, and W8 | `docs/window-state-gates.md` §10, §11 |
| Export acceptance | HTML/PDF/Print shipped (PR F #138, PR G #147). Open: E3 kitchen-sink output; E5 shared snapshot for PDF and Print; E6 fresh-panel URL and leaf-grant owner smoke; E7 PDF panel defaults, the real HTML panel, PDF failure/Print cancel feedback, and the keyboard/VoiceOver owner smoke; E9 keyboard-only HTML and PDF/Print accessibility, typing-path isolation while exporting, and the regression bullet | `docs/export-gates.md` §8 |
| R17 sidebar stability | macOS 15 exact-head CI and owner macOS 27 F9/WS4A UI re-verification | `docs/risk-register.md` R17 |
| Release §12 budgets | Re-run all budgets on the Release configuration at the 1.0 candidate commit; new `docs/perf/` entry | `agent.md` §12, release plan P5 |
| Clean-machine install | Signed DMG on a second Mac with no Gatekeeper bypass; workspace, edit/save, offline preview | release plan P5 (signed wording) |
| Docs | README: remove the bypass instructions, refresh Known limitations; Traditional Chinese README in sync | `README.md` |

### Should

| Item | Remaining work | Source of truth |
|---|---|---|
| Native window tabs | Windows PR F, after D2 (WD4 already decided: in scope) | `docs/window-state-gates.md` WD4 |
| Window/tab restoration | Windows PR E, after F and the WD5 decision (still open) | `docs/window-state-gates.md` §6.4, §9 |
| Preview residency and dual-window acceptance | Windows PR G (memory/typing with several windows, XCUITest, accessibility), after WD6's residency half and the §7.3 budget are decided | `docs/window-state-gates.md` §7, W11–W13 |
| In-app updates | U2 (appcast script, feed workflow, keys, CI secret) and U3 (end-to-end gate on a signed build), per V5 | `docs/auto-update-plan.md` §4, §5 |
| R21 CI resource failures | None unless it recurs. The 2026-10-29 audit (#231) lowered R21 to Low as an accepted residual; its recurrence signature raises it back to Medium | `docs/risk-register.md` R21 |

### Deferred (stays a Known limitation)

- WYSIWYG stable/default promotion (V3) and its raw/deferred constructs (tables, fences,
  Mermaid/math, reference links, autolinks, SVG/remote/single-file images).
- Real MDX component execution (agent.md §9 Phase 3+).
- User CSS, per-slot fonts, and imported themes in the preview. Editor color theme
  import landed in #234; the preview keeps its built-in palettes
  (`docs/custom-themes-design.md`).
- SVG outside workspace image mode: `data:` SVG, inline `<svg>`, SVG in HTML/PDF export,
  and validation of remote SVG. Workspace SVG in the preview landed in #229
  (`docs/svg-preview-design.md`).
- Single-file sibling images without a folder grant.
- Mac App Store build.

## 3. iOS 1.0

Every item below is currently OPEN in `docs/ios/integration-ledger.md` (2026-10-26
section) unless noted. #228 (2026-10-29) added features but closed no device gate. Most
items need the owner with physical hardware.

### Must

| Item | Remaining work |
|---|---|
| Signed install | Sign the Release IPA and install it on a real device (needs the same Developer Program membership as macOS P1) |
| Files / iCloud | Open, edit, save and reopen in place through Files and iCloud Drive, including offline/downloading documents |
| Chinese IME and Undo | Physical Zhuyin and Pinyin composition plus Undo/Redo in the native editor (agent.md §13 treats IME as non-negotiable) |
| Recovery, conflict, background | Real recovery list, conflict Save a Copy, and backgrounding/termination without data loss |
| Export and print | HTML/PDF export and printing on a physical device (#228 left these to owner validation; not yet in the ledger) |
| Minimum OS and iPad | Physical iPad and an iOS 26.0 device |
| Accessibility | VoiceOver and hardware-keyboard flows |
| Performance | Measured typing, open and preview budgets on device, recorded under `docs/perf/` |
| Distribution | TestFlight beta, then App Store review (screenshots, metadata, privacy manifest review; #228 added the UserDefaults manifest entry and the app icon) |

### Should

- iPad multitasking/split view polish beyond the M0 layouts.
- Feature parity items the Mac has but iOS v1 contracts leave out (decide per item; list
  them in `docs/ios/contracts.md` rather than here).

### Deferred

- WYSIWYG on iOS (#228 does not expose it). Folder search is no longer deferred: #228
  added it.

## 4. Proposed order

1. Owner decides V1–V6.
2. Buy Developer Program membership → macOS P1/P2 → first signed `0.9.0` beta from the
   current feature set (de-risks signing before D2 and the later Windows PRs land).
3. Windows D1b (#239) → D1c (#240) → D2, each with its hosted gates; signed `0.9.x`
   betas after each. C, D1-0, and D1a are already merged.
4. Close the export E-gates, R17 and the Release-configuration budget run in parallel.
5. Should items (F, then E after WD5, G after WD6's residency half, and updates U2/U3)
   as time allows; cut `1.0.0` from a commit with the full `make test` green and the
   clean-machine install done.
6. iOS: owner device pass over §3 Must → TestFlight → App Store, on its own timeline.

## 5. Exit checklist (macOS 1.0)

- [ ] V1–V6 recorded in `docs/decisions/`.
- [ ] Signed, notarized, stapled DMG built by release CI.
- [ ] Windows PR C, D1a–D1c, and D2 merged with their named gates (C #230 and D1a #238
  are merged).
- [ ] Remaining `docs/export-gates.md` boxes checked or moved to Deferred by the owner.
- [ ] R17 re-verification done. (R21's accepted residual is already recorded: #231,
  2026-10-29.)
- [ ] §12 budgets re-measured on the Release configuration at the candidate commit.
- [ ] Clean-machine install with no Gatekeeper bypass.
- [ ] README (both languages) updated; WYSIWYG still labelled Experimental.
