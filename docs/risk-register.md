# Risk Register

Status snapshot: 2026-06-25.

This register captures the risks that should drive the next roadmap decisions. Severity is based on
impact to editor correctness, user trust, or ability to enter Phase 2 safely.

| ID | Risk | Severity | Current signal | Mitigation / next action | Owner surface |
|---|---|---:|---|---|---|
| R1 | M5 can be declared accepted before the checklist passes | High | Performance, security, Settings/themes, real-content, launch-stability, and Open Recent checks are in place; `docs/m5-checklist.md` still has four unchecked manual editor-input blockers | Keep `docs/perf-log.md` honest; do not call M5 accepted until `docs/m5-checklist.md` fully passes | Docs, PerformanceTests |
| R2 | Visible-range highlighting regresses after PR #20 | Medium | PR #20 plumbed visible-range-first request/apply, measured Markdown 17.918 ms max and MDX 22.670 ms max, and closed #14 | Keep PerformanceTests and scheduling regression coverage in place before Phase 2 folding work | EditorKit, PerformanceTests |
| R3 | Memory gate scope is misunderstood after PR #21/#22 | Medium | PR #21 records 149.8 MB host RSS with 8 warm sessions and 2 settled live webviews; PR #22 clarified host-process RSS scope and #13 is closed | Keep M5 scoped to host-process RSS and keep helper-inclusive memory diagnostic unless a future system-footprint budget is created | App, PreviewKit, PerformanceTests |
| R4 | MDX sanitizer schema can regress toward active/spoofing HTML | Medium | Mitigated by PR #24/#27: inline `style` is stripped, script-like elements are dropped before sanitize, inline SVG/path is dropped before sanitize, and malicious snapshot coverage exists | Keep malicious snapshot coverage; require a new Decision Log entry before allowing any user-authored inline CSS or SVG | preview-src |
| R5 | Local asset and image import paths can read large or active files into memory | Medium | Mitigated by PR #24: preview/imported assets are limited to PNG, JPEG, GIF, or WebP up to 10 MiB and external image copies avoid whole-file `Data(contentsOf:)` reads | Keep size/type/path rejection tests; create a separate sanitizer/design before allowing SVG or larger managed assets | PreviewKit, WorkspaceKit |
| R6 | Settings/themes can regress after manual validation | Medium | PR #26 closed #16 with Settings panes, UserDefaults persistence, live editor/preview settings, and remote-image policy tests; PR #30's 2026-06-25 sweep manually confirmed the settings workflow, theme changes, Mermaid theme behavior, and persistence | Keep Settings/theme checks in the M5 checklist as regression evidence; keep custom editor-theme JSON and user CSS deferred until separate designs exist | App, EditorKit, PreviewKit |
| R7 | Preview render cost can grow with large DOM/code/Mermaid content | Medium | Current render path rewrites assets, highlights code, renders Mermaid, and scans line anchors | Cache code highlighting/Mermaid by source hash; measure code-heavy and Mermaid-heavy fixtures | preview-src, PerformanceTests |
| R8 | Documentation drift causes Codex/agents to work from stale milestone assumptions | Medium | #17/PR #24 and PR #26/#27 status both needed follow-up synchronization after merge | Keep README, `agent.md`, `docs/m5-plan.md`, and this file synchronized per PR | Docs |
| R9 | Phase 2 WYSIWYG starts before Phase 1 stabilizes | High | WYSIWYG is tempting but agent.md marks IME/undo/selection as highest risk | Only run design/spikes until M5 is accepted and `docs/wysiwyg-design.md` is approved; v1 scope should be inline-only | EditorKit, docs |
| R10 | CJK IME correctness regresses when styling/folding increases | High | `agent.md` says IME correctness is non-negotiable; Phase 2 will stress it | Add IME marked-text regression coverage before delimiter folding or visual replacement work | EditorKit |
| R11 | CI misses TypeScript type errors | Low | PR #22 added explicit `cd preview-src && npm run typecheck` coverage and #18 is closed | Keep `npm test` and `npm run typecheck` as separate CI commands so failures are easy to diagnose | CI, preview-src |
| R12 | Public alpha starts without release hardening | Medium | License, signing, hardened runtime, notarization, and release packaging are not final | Keep public release blocked until license and release pipeline are decided | Release/docs |
| R13 | Hosted CI runner variance can fail WebKit preview timing despite local M5 evidence | Medium | PR #20/#21 GitHub `macos-15` runs exceeded the 100 ms Markdown preview budget while local PR #15 evidence passed | Keep CI preview timing informational and require local/result-bundle evidence before accepting the M5 preview gate | PerformanceTests, docs |
| R14 | Helper-inclusive WebKit memory can exceed the M5 host RSS budget | Medium | PR #21 recorded 149.8 MB host RSS but 648.3 MB host + WebKit helper aggregate | Keep M5 scoped to host RSS; open a separate system-footprint budget if Activity Monitor-style aggregate memory becomes a release requirement | PerformanceTests, PreviewKit |
| R15 | Restoring the native adjustable sidebar can reintroduce launch instability | Medium | PR #30 replaced `NavigationSplitView` after it caused an AppKit constraint-loop crash during manual launch; a fixed-width sidebar/detail `HStack` is accepted as the M5 stability tradeoff | Keep the `HStack` shell for M5; restore an adjustable/native sidebar only as post-M5 polish after reproducing and isolating the AppKit constraint loop | App |

## Immediate risk burn-down order

1. PR #15/#20/#21/#22/#24/#26/#27/#29/#30 have landed; keep them as feature/performance/CI/security/checklist evidence, not full M5 acceptance.
2. Resolve the remaining unchecked manual editor-input items in `docs/m5-checklist.md`.
3. Mark M5 accepted only after the checklist fully passes.
4. Keep R15 as post-M5 polish; do not fold adjustable/native sidebar restoration into the remaining M5 blocker work.
5. Keep R14 visible for any future helper-inclusive memory budget.
6. Keep R13 visible whenever CI is green from informational preview timing.
7. Keep public release hardening (license, signing, notarization, packaging) separate from the M5 feature exit.
8. Only then advance the Phase 2 WYSIWYG design from draft to approved; do not start implementation before M5 is accepted and the design gate is approved.
