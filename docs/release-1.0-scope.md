# Release 1.0 Scope (Draft)

> **Status: DRAFT, 2026-10-29. Nothing here is decided until the owner signs off the
> [owner] items below.** This file proposes what "1.0" means for each platform and lists
> the remaining work against the gates that already exist. It does not replace those gate
> documents; each row points at the source of truth.

Baseline: macOS `v0.1.0-alpha.5` (build 189, `a210f85`, published 2026-10-28) is an
unsigned public alpha. iOS has a production composition candidate on `main`
(`docs/ios/integration-ledger.md`, 2026-10-26) and no published build.

Tiers used below:

- **Must** — 1.0 does not ship without it.
- **Should** — planned for 1.0; may slip to 1.0.x with an owner decision.
- **Deferred** — explicitly not in 1.0; stays documented as a known limitation.

## 1. Owner decisions needed first

| ID | Question | Proposed default | Why it matters |
|---|---|---|---|
| V1 | Do macOS and iOS ship 1.0 together? | **No.** macOS 1.0 first; iOS follows as its own 1.0 | iOS still has every device gate open; tying them blocks macOS on hardware evidence |
| V2 | Is multi-window (Windows PR C–G) in macOS 1.0? | **Yes, through D2**; native tabs (F), restoration (E) and residency (G) are Should | Today a second window mirrors the first (agent.md §5), which reads as a bug |
| V3 | WYSIWYG at 1.0? | **Ships Experimental, off by default** (no promotion) | Promotion needs the `docs/wysiwyg-release-checklist.md` §D.4 gate and a Decision Log entry |
| V4 | Distribution channel | **Direct DMG, Developer ID + notarized**; Mac App Store later | agent.md §15 locks direct distribution first |
| V5 | Updates | **Sparkle-style in-app updates are Should**; at minimum a documented manual update path. Plan: `docs/auto-update-plan.md` | README lists "no auto-update"; a new dependency needs a Decision Log entry (agent.md §2) |
| V6 | Version and channel naming | `1.0.0`, with `0.9.x` signed betas before it | `MARKETING_VERSION` is still `0.1.0` (release plan P0.5) |

## 2. macOS 1.0

### Must

| Item | Remaining work | Source of truth |
|---|---|---|
| Developer ID signing + hardened runtime | Buy Apple Developer Program membership; resume P1; confirm `get-task-allow` stays absent | `docs/release-engineering-plan.md` P1 |
| Notarization + stapling | P2 in the release workflow; signed CI path | `docs/release-engineering-plan.md` P2, P4 |
| Independent windows | Windows PR C, D1, D2 with their W0–W8 gates; R22's 16× hosted reruns before C's command routing is accepted | `docs/window-state-gates.md` §10, `docs/risk-register.md` R22 |
| Export acceptance | HTML/PDF/Print shipped (PR F #138, PR G #147); close the remaining E1/E5–E9 boxes (kitchen-sink fidelity, leaf-grant owner smoke, failure/cancel feedback, keyboard/VoiceOver, typing-path isolation) | `docs/export-gates.md` |
| R17 sidebar stability | macOS 15 exact-head CI and owner macOS 27 F9/WS4A UI re-verification | `docs/risk-register.md` R17 |
| Release §12 budgets | Re-run all budgets on the Release configuration at the 1.0 candidate commit; new `docs/perf/` entry | `agent.md` §12, release plan P5 |
| Clean-machine install | Signed DMG on a second Mac with no Gatekeeper bypass; workspace, edit/save, offline preview | release plan P5 (signed wording) |
| Docs | README: remove the bypass instructions, refresh Known limitations; Traditional Chinese README in sync | `README.md` |

### Should

| Item | Remaining work | Source of truth |
|---|---|---|
| Native window tabs | Windows PR F (WD4 already decided: in scope) | `docs/window-state-gates.md` WD4 |
| Window/tab restoration | Windows PR E | `docs/window-state-gates.md` §6.4 |
| Preview residency and dual-window acceptance | Windows PR G (memory/typing with two windows, XCUITest, accessibility) | `docs/window-state-gates.md` W11–W13 |
| In-app updates | Per V5 | — |
| R21 CI resource failures | Root cause from retained evidence, so release CI is trustworthy | `docs/risk-register.md` R21 |

### Deferred (stays a Known limitation)

- WYSIWYG stable/default promotion (V3) and its raw/deferred constructs (tables, fences,
  Mermaid/math, reference links, autolinks, SVG/remote/single-file images).
- Real MDX component execution (agent.md §9 Phase 3+).
- Custom theme JSON and user CSS (agent.md §11).
- SVG preview images; single-file sibling images without a folder grant.
- Mac App Store build.

## 3. iOS 1.0

Every item below is currently OPEN in `docs/ios/integration-ledger.md` (2026-10-26
section) unless noted. Most need the owner with physical hardware.

### Must

| Item | Remaining work |
|---|---|
| Signed install | Sign the Release IPA and install it on a real device (needs the same Developer Program membership as macOS P1) |
| Files / iCloud | Open, edit, save and reopen in place through Files and iCloud Drive, including offline/downloading documents |
| Chinese IME and Undo | Physical Zhuyin and Pinyin composition plus Undo/Redo in the native editor (agent.md §13 treats IME as non-negotiable) |
| Recovery, conflict, background | Real recovery list, conflict Save a Copy, and backgrounding/termination without data loss |
| Minimum OS and iPad | Physical iPad and an iOS 26.0 device |
| Accessibility | VoiceOver and hardware-keyboard flows |
| Performance | Measured typing, open and preview budgets on device, recorded under `docs/perf/` |
| Distribution | TestFlight beta, then App Store review (privacy manifest, screenshots, metadata) |

### Should

- iPad multitasking/split view polish beyond the M0 layouts.
- Feature parity items the Mac has but iOS v1 contracts leave out (decide per item; list
  them in `docs/ios/contracts.md` rather than here).

### Deferred

- WYSIWYG on iOS; workspace search on iOS unless already in the v1 contracts.

## 4. Proposed order

1. Owner decides V1–V6.
2. Buy Developer Program membership → macOS P1/P2 → first signed `0.9.0` beta from the
   current feature set (de-risks signing before the large Windows PRs land).
3. Windows PR C → D1 → D2, each with its hosted gates; signed `0.9.x` betas after each.
4. Close the export E-gates, R17 and the Release-configuration budget run in parallel.
5. Should items (F, E, G, updates) as time allows; cut `1.0.0` from a commit with the
   full `make test` green and the clean-machine install done.
6. iOS: owner device pass over §3 Must → TestFlight → App Store, on its own timeline.

## 5. Exit checklist (macOS 1.0)

- [ ] V1–V6 recorded in `docs/decisions/`.
- [ ] Signed, notarized, stapled DMG built by release CI.
- [ ] Windows PR C, D1, D2 merged with their named gates.
- [ ] Remaining `docs/export-gates.md` boxes checked or moved to Deferred by the owner.
- [ ] R17 re-verification done; R21 has a recorded root cause or accepted residual.
- [ ] §12 budgets re-measured on the Release configuration at the candidate commit.
- [ ] Clean-machine install with no Gatekeeper bypass.
- [ ] README (both languages) updated; WYSIWYG still labelled Experimental.
