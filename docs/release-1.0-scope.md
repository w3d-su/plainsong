# Release 1.0 Scope

> **Status: V1, V2, V4, V5 and V6 decided by the owner on 2026-11-10
> (`docs/decisions/2026-11-10-release-1.0-scope.md`), V3 on 2026-11-11
> (`docs/decisions/2026-11-11-release-1.0-scope-v3-wysiwyg.md`).** Drafted
> 2026-10-29; refreshed 2026-11-10 against `main` at `2a555d9` (#253). This file says
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

## 1. Owner decisions

| ID | Question | Decision or proposed default | Why it matters |
|---|---|---|---|
| V1 | Do macOS and iOS ship 1.0 together? | **Decided 2026-11-10: no.** macOS 1.0 first; iOS follows as its own 1.0 | iOS still has every device gate open; tying them blocks macOS on hardware evidence |
| V2 | Is multi-window (Windows PR C–G) in macOS 1.0? | **Decided 2026-11-10: yes, through D2**; native tabs (F), restoration (E) and residency (G) are Should | Without D2 a user cannot work in a second window: New Window is not offered, and a second scene refuses file and root opens and closes itself (agent.md §5). D2 is draft #246 |
| V3 | WYSIWYG at 1.0? | **Decided 2026-11-11: promoted.** WYSIWYG leaves Experimental for 1.0 through #213: on by default and a stop in the layout cycle, not the first-launch layout, with the Settings switch kept as the kill switch | The owner chose promotion over shipping it Experimental and off by default (the draft default). The decision sets the target; it does not close the gate. #213 still merges only after the `docs/wysiwyg-release-checklist.md` §D.4 gate: the owner's Zhuyin/Pinyin and pointer dogfood, since the last real IME runs predate STTextView 2.4.1 (R9), and a Decision Log entry |
| V4 | Distribution channel | **Decided 2026-11-10: unsigned direct DMG** (ad-hoc signature, README Gatekeeper bypass on first install). The Apple Developer Program membership is not planned in the short term; Developer ID signing, notarization and a Mac App Store build wait for it | agent.md §15 locks direct distribution first. The draft default was a signed, notarized DMG |
| V5 | Updates | **Decided 2026-11-10: in-app updates are Must.** Sparkle 2 is integrated and off (U1, #232); turning it on needs U2 and U3 (`docs/auto-update-plan.md` §4). With V4 this means updating unsigned builds (U-D2) | An owner-run probe on 2026-11-10 updated an unsigned build with no second Gatekeeper prompt (`docs/auto-update-plan.md` §5). U-D4–U-D7 were adopted the same day (U-D6 reverses the 2026-07-02 no-secrets rule). README keeps "no auto-update" until U3 |
| V6 | Version and channel naming | **Decided 2026-11-10: `1.0.0`**, with `0.9.x` betas before it; all unsigned, per V4 | `MARKETING_VERSION` is still `0.1.0` (release plan P0.5) |

## 2. macOS 1.0

### Must

| Item | Remaining work | Source of truth |
|---|---|---|
| Independent windows | C (#230), D1-0 (#236), D1a (#238), D1b (#239) and D1c (#252) are merged. D2 is draft #246, up to date with `main` and green; it waits on the owner smoke for W0 bullets 1–4, W7 bullet 3 and W8 bullet 1 | `docs/window-state-gates.md` §10, §11 |
| Export acceptance | HTML/PDF/Print shipped (PR F #138, PR G #147). Open: E3 kitchen-sink output; E5 shared snapshot for PDF and Print; E6 fresh-panel URL and leaf-grant owner smoke; E7 PDF panel defaults, the real HTML panel, PDF failure/Print cancel feedback, and the keyboard/VoiceOver owner smoke; E9 keyboard-only HTML and PDF/Print accessibility, typing-path isolation while exporting, and the regression bullet | `docs/export-gates.md` §8 |
| R17 sidebar stability | macOS 15 exact-head CI and owner macOS 27 F9/WS4A UI re-verification | `docs/risk-register.md` R17 |
| Release §12 budgets | Re-run all budgets on the Release configuration at the 1.0 candidate commit; new `docs/perf/` entry | `agent.md` §12, release plan P5 |
| In-app updates | U2 and U2b are merged (#257, #258): the tag job signs the feed, release builds have updates on, and the key pair and CI secret exist. Open: U3's end-to-end gates U-G4–U-G8 on unsigned builds, starting with the first tagged release | `docs/auto-update-plan.md` §4, §5 |
| Clean-machine install | The unsigned release DMG on a second Mac, through the documented Gatekeeper bypass: workspace, edit/save, offline preview | release plan P5 |
| WYSIWYG promotion (V3) | Owner dogfood and actual-IME sign-off on a build of #213 (its ten-item checklist; IME and pointer are blocking), then fill #213's decision entry and the §D.4 evidence line and merge it | `docs/wysiwyg-release-checklist.md` §D.4, draft #213 |
| Docs | README: refresh Known limitations and replace "no auto-update"; keep the bypass instructions while builds are unsigned; Traditional Chinese README in sync | `README.md` |

### Should

| Item | Remaining work | Source of truth |
|---|---|---|
| Native window tabs | Windows PR F, after D2 (WD4 already decided: in scope) | `docs/window-state-gates.md` WD4 |
| Window/tab restoration | Windows PR E, after F and the WD5 decision (still open) | `docs/window-state-gates.md` §6.4, §9 |
| Preview residency and dual-window acceptance | Windows PR G (memory/typing with several windows, XCUITest, accessibility), after WD6's residency half and the §7.3 budget are decided | `docs/window-state-gates.md` §7, W11–W13 |
| R21 CI resource failures | None unless it recurs. The 2026-10-29 audit (#231) lowered R21 to Low as an accepted residual; its recurrence signature raises it back to Medium | `docs/risk-register.md` R21 |

### Deferred (stays a Known limitation)

- WYSIWYG's raw/deferred constructs (tables, fences, Mermaid/math, reference links,
  autolinks, SVG/remote/single-file images). Promotion (V3) does not change them.
- Real MDX component execution (agent.md §9 Phase 3+).
- User CSS, per-slot fonts, and imported themes in the preview. Editor color theme
  import landed in #234; the preview keeps its built-in palettes
  (`docs/custom-themes-design.md`).
- SVG outside workspace image mode: `data:` SVG, inline `<svg>`, SVG in HTML/PDF export,
  and validation of remote SVG. Workspace SVG in the preview landed in #229
  (`docs/svg-preview-design.md`).
- Single-file sibling images without a folder grant.
- Developer ID signing, notarization and stapling (release plan P1/P2), and a Mac App
  Store build: all wait for the Apple Developer Program membership (V4).

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

1. Owner runs the Zhuyin/Pinyin and pointer dogfood on #213 (V3 is decided: promote);
   #213 merges when it passes.
2. Owner smoke for D2 (#246), then merge it. C, D1-0 and D1a–D1c are already merged.
3. First `0.9.0` beta with updates on (U2 and U2b are merged; the key and secret exist)
   → U3 against the real feed.
4. Close the export E-gates, R17 and the Release-configuration budget run in parallel;
   `0.9.x` betas as they land.
5. Should items (F, then E after WD5, G after WD6's residency half) as time allows; cut
   `1.0.0` from a commit with the full `make test` green and the clean-machine install
   done.
6. iOS: owner device pass over §3 Must → TestFlight → App Store, on its own timeline.

## 5. Exit checklist (macOS 1.0)

- [x] V1–V6 recorded in `docs/decisions/` (V1, V2, V4, V5 and V6: 2026-11-10; V3:
  2026-11-11).
- [ ] WYSIWYG promoted (V3): #213 merged with checklist §D.4 checked.
- [ ] Unsigned DMG built by release CI (V4).
- [ ] Windows PR C, D1a–D1c, and D2 merged with their named gates (all but D2, #246, are
  merged).
- [ ] In-app updates on: U2 merged and U-G4–U-G8 checked.
- [ ] Remaining `docs/export-gates.md` boxes checked or moved to Deferred by the owner.
- [ ] R17 re-verification done. (R21's accepted residual is already recorded: #231,
  2026-10-29.)
- [ ] §12 budgets re-measured on the Release configuration at the candidate commit.
- [ ] Clean-machine install through the documented Gatekeeper bypass.
- [ ] README (both languages) updated; WYSIWYG no longer labelled Experimental (#213).
