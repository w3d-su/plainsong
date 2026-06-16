# M5 Slice Plan & Dependency Order

> Living plan for M5 (MDX + polish, agent.md §14). M5 is too large for one PR, so it is split
> into five PR-sized slices, each its own `m5-*` branch and PR (agent.md §17 rule 2).
> Status snapshot: **2026-06-17**.

## Slice catalog

| Slice | Content | Primary surface (layers/files) | New dependency / gate | Status |
|---|---|---|---|---|
| **1 — MDX preview** | mdx pipeline + non-executed placeholders + inline error banner / last-good DOM | `preview-src/`, `PreviewKit` | `remark-mdx`, `mdast-util-mdx`, `rehype-sanitize` (Decision Log added); protocol stays v4 | ✅ PR #8 — implemented & verified, **awaiting maintainer merge** |
| **2 — tsx highlighting** | MDX editor tsx-injection (replace coarse `.mdxSource` token) | `EditorKit`, `Package.swift`, `project.yml` | **tsx grammar (needs Decision Log; highest technical risk)** | Not started |
| **3 — Settings + themes** | §11 panes + editor/preview themes, user CSS override | `App`, `EditorKit` (theme), `preview-src/styles` | none new (reuses `setTheme`, Yams already in); **relaxes §7.1 CSP** for remote images | Not started |
| **4 — App icon + polish** | populate AppIcon + AccentColor, light/dark coherence | `App/Resources/Assets.xcassets` (+ icon-gen script) | none (but **icon/accent need maintainer design sign-off**) | Not started |
| **5 — Performance pass** | measure + record §12 budgets, add PerformanceTests target | `PerformanceTests`, `Fixtures/`, `docs/perf-log.md` | none; adds a test target | Not started (**do last**) |

## Dependency matrix

| Slice | Depends on | Can run in parallel with |
|---|---|---|
| 1 | — | 2, 4 |
| 2 | — | 1, 4 |
| 3 | (soft) 1, 2 | 4 |
| 4 | — | 1, 2, 3 |
| 5 | **1, 2, 3, 4 (all)** | — |

## Recommended merge order (linear)

```
1 (MDX preview, awaiting merge)
  → 4 (app icon — insertable anytime, no conflicts)
  → 3 (Settings + themes)
  → 2 (tsx highlighting)
  → 5 (perf pass — after everything)
```

2 and 3 may swap, but **must be sequenced (not parallel)** — see conflict hotspots. 3-before-2 is
recommended so tsx capture colors slot into the finished theme system (JSON / light-dark) rather than
being rewritten once. If MDX editor fidelity is higher priority, run 2 first; the second lander rebases.

## Parallel waves (handoff view)

- **Dispatchable now (no shared files):** slice 2 and slice 4 (slice 1 is already done).
- **Slice 3** should wait until slice 1 is merged (shared `preview-src/src/styles/base.css`) and be
  sequenced with slice 2 (shared `MarkdownSyntaxTheme.swift`).
- **Slice 5** starts only after 1–4 are merged (it measures the whole M5 system).

## Conflict hotspots (same file → sequence, don't parallelize)

| File | Touched by | Handling |
|---|---|---|
| `preview-src/src/styles/base.css` | 1 (placeholder styles) + 3 (theme CSS) | land 1 before 3; 3 rebases |
| `Packages/EditorKit/Sources/EditorKit/MarkdownSyntaxTheme.swift` | 2 (tsx token colors) + 3 (theme JSON/light-dark) | sequence 2 & 3; second rebases |
| `agent.md` (Decision Log / §16 fixtures / §12) | 2 (tsx dep), 5 (fixtures + perf note) | each adds its entry; watch the merge |
| `project.yml` / `Package.resolved` | 2 (grammar dep) | only slice 2 touches; standalone |

## Risks & caveats

- **Slice 2 tsx grammar dependency** is the biggest M5 technical risk: compatibility with the pinned
  `swift-tree-sitter` 0.10.0 and the Neon-vs-grammar pin conflict noted in the Decision Log. Mitigation:
  vendor the tsx C source as an SPM target (mirror `TreeSitterYAMLFixed`). Start early to surface risk.
- **Slice 5 must not fake passes.** Per the §12 M5 planning note: the highlight-update budget is not
  accepted until visible-range highlighting is plumbed/instrumented (the parser defers inline parsing above
  250 KB, so that cutoff is not a pass); the memory budget is the 2-webview gate (single-webview numbers are
  informational only). Record these honestly as blocked/informational if the prerequisites are absent.

## Docs landing gap

`docs/m5-checklist.md` and `docs/perf-log.md` exist locally but are **not on `main`** yet. Land the
checklist early (it is the M5 acceptance script) via a small docs PR; `perf-log.md` lands filled-in with
slice 5. This file (`docs/m5-plan.md`) is also not yet on `main`.

## Status snapshot (2026-06-17)

- M4 fully merged to `main` (PR #7), including the smart-paste symlink containment fix.
- M5 sequencing gate (agent.md §14) is **cleared**.
- Slice 1 (PR #8) implemented, reviewed, and verified (MDX placeholders, sanitization, error liveness,
  data-line, math-through-sanitize all confirmed; the `.mdx` checkbox-`disabled` regression was fixed and
  re-verified). Awaiting maintainer squash-merge.
- Next actions: merge slice 1; dispatch slice 2 and slice 4 in parallel.

---

# Beyond M5 — Roadmap & Scheduling

> There is **no "M6"** in agent.md. After M5 (the last Phase 1 milestone) the roadmap is Phase 2
> (WYSIWYG, §13) then Phase 3 (unscheduled candidates, §14). This section sequences the path forward.

## Sequence

| Stage | Deliverable | Prerequisite / gate | Risk | Decision owner |
|---|---|---|---|---|
| **A. Finish M5** | slices 2→5 merged; `docs/m5-checklist.md` passes; §12 budgets recorded | slice 1 merged | med (slice 2 tsx dep) | dev (per slice plan above) |
| **B. Phase 2 design** | `docs/wysiwyg-design.md` approved + spikes A/B/C (IME, undo, selection) | **M1–M5 complete** (agent.md §13) | high (this is the gate) | **maintainer** approves design |
| **C. Phase 2 build** | WYSIWYG v1 behind ⌘⇧P (fold/reveal engine + low-risk constructs first; tables/mermaid last) | stage B approved | very high (TextKit 2, IME) | dev, after B sign-off |
| **(opt) Phase 3 slice** | e.g. export HTML/PDF via preview print (lowest-risk, reuses preview) | maintainer schedules it (Phase 3 is "not scheduled") | low–med | **maintainer** product call |

## Decision point (maintainer)

After M5, choose: **(1)** go straight to Phase 2 (write/approve `wysiwyg-design.md` → spikes → build), or
**(2)** insert a Phase 3 slice (export is the cheapest visible win) before taking on WYSIWYG risk.
Recommended default: **finish M5 → write the WYSIWYG design doc + run the IME/undo/selection spikes
(risk discovery) → then decide Phase 2 build vs. an interim export slice.** Phase 3 ordering needs a
Decision Log entry since agent.md marks it unscheduled.

## "M6" naming note

If the M-numbering is kept past M5, the de-facto "M6" is **Phase 2 WYSIWYG** — but it is gated on the
design doc above, so its first deliverable is `docs/wysiwyg-design.md` + spikes, not feature code.
