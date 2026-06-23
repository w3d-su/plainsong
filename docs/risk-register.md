# Risk Register

Status snapshot: 2026-06-23.

This register captures the risks that should drive the next roadmap decisions. Severity is based on
impact to editor correctness, user trust, or ability to enter Phase 2 safely.

| ID | Risk | Severity | Current signal | Mitigation / next action | Owner surface |
|---|---|---:|---|---|---|
| R1 | M5 can be declared complete before the real performance gates are done | High | PR #15 adds infrastructure, but #13 and #14 remain open | Keep `docs/perf-log.md` honest; do not close M5 until visible-range highlight and 2-webview memory gates pass | Docs, PerformanceTests |
| R2 | Visible-range highlighting is not plumbed/instrumented | High | Issue #14 open; current parser has large-doc inline parsing cutoff | Implement visible-range-first highlight request/apply path and signposted test coverage | EditorKit, PerformanceTests |
| R3 | Memory budget lacks deterministic 2-live-webview harness | High | Issue #13 open; PR #15 records single-webview memory only | Add deterministic harness/workflow for 8 warm sessions + 2 live previews and update perf log | App, PreviewKit, PerformanceTests |
| R4 | MDX sanitizer schema is broader than needed | High | Review found broad `style` allowance risk | Tighten schema; add malicious MDX/HTML snapshot tests for style spoofing, event handlers, scripts, giant layout | preview-src |
| R5 | Local asset and image import paths can read whole large files into memory | Medium | Review found `Data(contentsOf:)` on asset/image paths | Add size/type guards and streaming or `FileManager.copyItem` where possible | PreviewKit, WorkspaceKit |
| R6 | Settings/themes are not implemented despite being in M5 scope | Medium | Search found no settings/theme implementation beyond icon/accent | Implement Settings scene panes or defer with Decision Log entry | App, EditorKit, PreviewKit |
| R7 | Preview render cost can grow with large DOM/code/Mermaid content | Medium | Current render path rewrites assets, highlights code, renders Mermaid, and scans line anchors | Cache code highlighting/Mermaid by source hash; measure code-heavy and Mermaid-heavy fixtures | preview-src, PerformanceTests |
| R8 | Documentation drift causes Codex/agents to work from stale milestone assumptions | Medium | README previously said M0–M2 only; `agent.md` still has older roadmap wording in some places | Keep README, `agent.md`, `docs/m5-plan.md`, and this file synchronized per PR | Docs |
| R9 | Phase 2 WYSIWYG starts before Phase 1 stabilizes | High | WYSIWYG is tempting but agent.md marks IME/undo/selection as highest risk | Only run design/spikes until M5 gates pass; v1 scope should be inline-only | EditorKit, docs |
| R10 | CJK IME correctness regresses when styling/folding increases | High | `agent.md` says IME correctness is non-negotiable; Phase 2 will stress it | Add IME marked-text regression coverage before delimiter folding or visual replacement work | EditorKit |
| R11 | CI misses TypeScript type errors | Low–Medium | `preview-src/package.json` has `typecheck`; CI coverage needs confirmation | Add `cd preview-src && npm run typecheck` to CI if absent | CI, preview-src |
| R12 | Public alpha starts without release hardening | Medium | License, signing, hardened runtime, notarization are not final | Keep public release blocked until license and release pipeline are decided | Release/docs |

## Immediate risk burn-down order

1. Review/land PR #15 as performance infrastructure, not as full M5 completion.
2. Close R2 via issue #14.
3. Close R3 via issue #13.
4. Close R4/R5 with a focused security hardening PR.
5. Implement or explicitly defer R6.
6. Only then advance the Phase 2 WYSIWYG design from draft to approved.
