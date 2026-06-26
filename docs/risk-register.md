# Risk Register

Status snapshot: 2026-06-26.

This register captures the risks that should drive the next roadmap decisions. Severity is based on
impact to editor correctness, user trust, or ability to enter Phase 2 safely.

| ID | Risk | Severity | Current signal | Mitigation / next action | Owner surface |
|---|---|---:|---|---|---|
| R1 | M5 acceptance evidence can drift after acceptance | Low | `docs/m5-checklist.md` passes after PR #33 | Keep README, `agent.md`, and planning docs synchronized with checklist evidence; reopen only on a real regression | Docs, PerformanceTests |
| R2 | Visible-range highlighting regresses after PR #20 | Medium | PR #20 measured Markdown 17.918 ms max and MDX 22.670 ms max and closed #14 | Keep PerformanceTests and scheduling regression coverage in place before Phase 2 folding work | EditorKit, PerformanceTests |
| R3 | Memory gate scope is misunderstood after PR #21/#22 | Medium | PR #21 records 149.8 MB host RSS; helper RSS is diagnostic | Keep M5 scoped to host RSS; create a separate system-footprint budget only if needed | App, PreviewKit, PerformanceTests |
| R4 | MDX sanitizer schema can regress toward active/spoofing HTML | Medium | Mitigated by PR #24/#27 | Keep malicious snapshot coverage; require a new Decision Log entry before allowing user-authored inline CSS or SVG | preview-src |
| R5 | Local asset and image import paths can read large or active files into memory | Medium | Mitigated by PR #24 with bounded raster-only policy | Keep size/type/path rejection tests; require a separate design before SVG or larger managed assets | PreviewKit, WorkspaceKit |
| R6 | Settings/themes can regress after manual validation | Medium | PR #26 landed settings; PR #30 manually confirmed workflows | Keep Settings/theme checks as regression evidence; keep custom theme JSON and user CSS deferred | App, EditorKit, PreviewKit |
| R7 | Preview render cost can grow with large DOM/code/Mermaid content | Medium | Preview still rewrites assets, highlights code, renders Mermaid, and scans line anchors | Cache code highlighting/Mermaid by source hash; measure code-heavy and Mermaid-heavy fixtures | preview-src, PerformanceTests |
| R8 | Documentation drift causes Codex/agents to work from stale milestone assumptions | Medium | Several milestone PRs needed follow-up synchronization | Keep README, `agent.md`, `docs/m5-plan.md`, and this file synchronized per PR | Docs |
| R9 | Phase 2 production implementation starts before spike results are accepted | High | This design gate approves spikes only; WYSIWYG implementation remains blocked | Run Spike A/B/C first and record go/no-go results before production implementation | EditorKit, docs |
| R10 | CJK IME correctness regresses when styling/folding increases | High | WYSIWYG folding can affect marked text ranges | Spike A must prove Zhuyin/Pinyin marked text correctness before implementation | EditorKit |
| R11 | Undo/redo stores stale presentation state | High | Folding attributes/layout may accidentally interact with undo | Spike B must prove undo remains source-text-only and presentation recomputes | EditorKit |
| R12 | Selection/copy across folded tokens maps to wrong source ranges | High | Hidden delimiters can confuse offset mapping and copied text | Spike C must prove arrow/shift/mouse selection and copy produce correct raw Markdown | EditorKit |
| R13 | CI misses TypeScript type errors | Low | PR #22 added explicit preview typecheck | Keep `npm test` and `npm run typecheck` separate in CI | CI, preview-src |
| R14 | Public alpha starts without release hardening | Medium | License, signing, hardened runtime, notarization, and packaging are not final | Keep public release blocked until release pipeline is decided | Release/docs |
| R15 | Hosted CI runner variance can fail WebKit preview timing despite local M5 evidence | Medium | GitHub runner timings can differ from local result-bundle evidence | Keep CI preview timing informational and require local/result-bundle evidence for perf gates | PerformanceTests, docs |
| R16 | Helper-inclusive WebKit memory can exceed the M5 host RSS budget | Medium | Helper aggregate RSS is diagnostic, not an M5 gate | Open a separate system-footprint budget only if Activity Monitor-style memory becomes a release requirement | PerformanceTests, PreviewKit |
| R17 | Restoring the native adjustable sidebar can reintroduce launch instability | Medium | PR #30 replaced `NavigationSplitView` after AppKit constraint-loop crash | Keep fixed-width `HStack` during Phase 2; restore adjustable sidebar only as post-M5 polish | App |

## Immediate risk burn-down order

1. Merge the Phase 2 design gate only if it stays docs/spikes-only.
2. Run Spike A/B/C: IME, undo, selection/copy.
3. Record go/no-go results before production WYSIWYG implementation.
4. Keep R17 as post-M5 polish; do not fold adjustable/native sidebar work into WYSIWYG spikes.
5. Keep release hardening separate from Phase 2 feature work.
