# Risk Register

Status snapshot: 2026-06-24.

This register captures the risks that should drive the next roadmap decisions. Severity is based on
impact to editor correctness, user trust, or ability to enter Phase 2 safely.

| ID | Risk | Severity | Current signal | Mitigation / next action | Owner surface |
|---|---|---:|---|---|---|
| R1 | M5 can be declared complete before remaining M5 exits are done | High | Performance and security have landed, but Settings/themes (#16), `docs/m5-checklist.md`, and final stale-doc review remain open | Keep `docs/perf-log.md` honest; do not close M5 until every remaining gate passes or is explicitly deferred | Docs, PerformanceTests |
| R2 | Visible-range highlighting regresses after PR #20 | Medium | PR #20 plumbed visible-range-first request/apply, measured Markdown 17.918 ms max and MDX 22.670 ms max, and closed #14 | Keep PerformanceTests and scheduling regression coverage in place before Phase 2 folding work | EditorKit, PerformanceTests |
| R3 | Memory gate scope is misunderstood after PR #21/#22 | Medium | PR #21 records 149.8 MB host RSS with 8 warm sessions and 2 settled live webviews; PR #22 clarified host-process RSS scope and #13 is closed | Keep M5 scoped to host-process RSS and keep helper-inclusive memory diagnostic unless a future system-footprint budget is created | App, PreviewKit, PerformanceTests |
| R4 | MDX sanitizer schema can regress toward active/spoofing HTML | Monitoring | PR #24 mitigated the active blocker by stripping inline `style`, event handlers, scripts, `srcdoc`, fixed overlays, giant layout, and background URL payloads from sanitized MDX/HTML | Keep malicious snapshot coverage; require a new Decision Log entry before allowing any user-authored inline CSS | preview-src |
| R5 | Local asset and image import paths can read large or active files into memory | Monitoring | PR #24 mitigated the active blocker by limiting preview/imported assets to PNG, JPEG, GIF, or WebP up to 10 MiB and copying external files without whole-file `Data(contentsOf:)` reads | Keep size/type/path rejection tests; create a separate sanitizer/design before allowing SVG or larger managed assets | PreviewKit, WorkspaceKit |
| R6 | Settings/themes are not implemented despite being in M5 scope | Medium | Issue #16 remains open and is the only remaining M5 feature gap; search found no settings/theme implementation beyond icon/accent | Implement Settings scene panes or defer with Decision Log entry | App, EditorKit, PreviewKit |
| R7 | Preview render cost can grow with large DOM/code/Mermaid content | Medium | Current render path rewrites assets, highlights code, renders Mermaid, and scans line anchors | Cache code highlighting/Mermaid by source hash; measure code-heavy and Mermaid-heavy fixtures | preview-src, PerformanceTests |
| R8 | Documentation drift causes Codex/agents to work from stale milestone assumptions | Medium | M5 docs require follow-up after each merged slice, especially around #16 and Phase 2 gating | Keep README, `agent.md`, `docs/m5-plan.md`, and this file synchronized per PR | Docs |
| R9 | Phase 2 WYSIWYG starts before Phase 1 stabilizes | High | WYSIWYG is tempting but agent.md marks IME/undo/selection as highest risk | Only run design/spikes until M5 is complete or remaining M5 scope is explicitly deferred; v1 scope should be inline-only | EditorKit, docs |
| R10 | CJK IME correctness regresses when styling/folding increases | High | `agent.md` says IME correctness is non-negotiable; Phase 2 will stress it | Add IME marked-text regression coverage before delimiter folding or visual replacement work | EditorKit |
| R11 | CI misses TypeScript type errors | Low | PR #22 added explicit `cd preview-src && npm run typecheck` coverage and #18 is closed | Keep `npm test` and `npm run typecheck` as separate CI commands so failures are easy to diagnose | CI, preview-src |
| R12 | Public alpha starts without release hardening | Medium | License, signing, hardened runtime, notarization are not final | Keep public release blocked until license and release pipeline are decided | Release/docs |
| R13 | Hosted CI runner variance can fail WebKit preview timing despite local M5 evidence | Medium | PR #20/#21 GitHub `macos-15` runs exceeded the 100 ms Markdown preview budget while local PR #15 evidence passed | Keep CI preview timing informational and require local/result-bundle evidence before accepting the M5 preview gate | PerformanceTests, docs |
| R14 | Helper-inclusive WebKit memory can exceed the M5 host RSS budget | Medium | PR #21 recorded 149.8 MB host RSS but 648.3 MB host + WebKit helper aggregate | Keep M5 scoped to host RSS; open a separate system-footprint budget if Activity Monitor-style aggregate memory becomes a release requirement | PerformanceTests, PreviewKit |

## Immediate risk burn-down order

1. PR #15/#20/#21/#22/#24 have landed; keep them as performance/CI/security evidence, not full M5 completion.
2. Implement or explicitly defer R6 via #16.
3. Keep R4/R5 as sanitizer/asset-policy regression watches after PR #24.
4. Keep R14 visible for any future helper-inclusive memory budget.
5. Keep R13 visible whenever CI is green from informational preview timing.
6. Only then run `docs/m5-checklist.md` and advance the Phase 2 WYSIWYG design from draft to approved.
