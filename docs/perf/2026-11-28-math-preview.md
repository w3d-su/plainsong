# Math-dense preview in Markdown and MDX

Measured 2026-11-28 on an Apple M1 Pro with 16 GB, macOS 27.0 (26A428), Xcode 27.0, Node 24.22.1 and lockfile Vitest 4.1.12. The baseline was `d9851d6c`. The comparison used the same source plus the math fragment change and a minified Safari-targeted production bundle.

## Settled WKWebView updates

`Fixtures/math-dense-100kb.md` has 100,155 bytes, 292 sections and 1,752 formulas. Each version changes one exponent in the middle. A fresh offscreen WKWebView loads the bundle for each file kind. The probe times the production `render` message through the matching `renderComplete`, waits for fonts and forces layout between samples, and checks the edited MathML annotation and all 1,752 formulas. After the initial render and three settling edits it records five edits. The §12 budget is under 100 ms after the 150 ms debounce.

| File kind | Baseline edits (ms) | Updated edits (ms) | Median, before → after | First render, before → after |
| --- | --- | --- | --- | --- |
| Markdown | 1082.2, 368.5, 347.2, 340.7, 350.6 | 27.8, 26.6, 28.0, 27.1, 29.6 | 350.6 → 27.8 ms | 503.2 → 326.6 ms |
| MDX | 335.0, 329.3, 362.2, 347.8, 338.9 | 27.6, 27.7, 29.5, 28.7, 28.2 | 338.9 → 28.2 ms | 821.8 → 309.4 ms |

Both settled medians passed the budget on this Mac. First render is still hundreds of milliseconds. The probe measures bridge completion. Time to display a painted frame, editor input latency and physical iOS devices are outside this measurement. The existing hosted performance gate uses the general 100 KB fixture.

In the same checkout, `PerformanceBudgetTests.testPreviewRenderFor100KBMarkdownAndMDXStaysUnderBudget` passed at 5.427 ms for Markdown and 15.215 ms for MDX. The hosted typing latency and visible-range highlighting gates also passed.

## Whole-document attribution

A separate baseline run timed `processor.parse`, `processor.runSync` and `processor.stringify` around the same VFile, and timed the `rehype-katex` transform inside `runSync`. One warmup preceded three measured renders per kind. Values are independent stage medians in milliseconds.

| Kind | Markdown/MDX parse | All transforms | Of which rehype-katex | Stringify | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Markdown | 103.1 | 944.7 | 904.3 | 192.3 | 1240.2 |
| MDX | 102.8 | 595.7 | 554.2 | 196.4 | 870.9 |

The largest stage renders TeX, parses its HTML back into HAST and replaces each formula. Timing `katex.renderToString` alone in a second paired run gave baseline medians of 125.1 ms for Markdown and 152.3 ms for MDX. Charging the whole transform to TeX layout would overstate that cost. Neither kind showed a multi-second parser stage here. The historical 6–7 s Markdown median did not reproduce in these focused runs.

## Repeated and distinct formulas

The control changes all six formulas in each section using the section number. It has 106,407 bytes, 1,752 different formulas and the same block structure. These are whole-document Node medians, with one warmup and three measured samples. Each baseline and updated pair produced byte-identical HTML for every measured source and file kind.

| Input | KaTeX calls before → after | Markdown before → after | MDX before → after |
| --- | ---: | ---: | ---: |
| Original, six distinct formulas | 1,752 → 6 | 874.6 → 98.6 ms | 943.3 → 105.1 ms |
| Distinct control | 1,752 → 1,752 | 923.9 → 870.7 ms | 961.5 → 971.0 ms |

The repeated input amplifies the benefit of formula reuse. The control still costs about a second to typeset in full. In WKWebView the control's settled edit medians fell from **458.4 to 37.4 ms** for Markdown and **404.2 to 42.8 ms** for MDX. First renders were 1130.9 → 1140.4 ms and 1173.7 → 1085.4 ms respectively. This pair ran updated first, with a repository build running in the background. A repeat on the original fixture under that load gave updated medians of 48.3 and 38.9 ms. Each run verified the annotation at the edited ordinal.

## Reproduction

Run the commands from the repository root on macOS. The Swift probe optionally takes a second bundle's `index.html` as its first argument for an A/B run against the same fixture.

```sh
(cd preview-src && npm ci && npm run build)
(cd preview-src && npm test -- math-perf --reporter=verbose --disableConsoleIntercept)
(cd preview-src && PLAINSONG_MATH_PERF_DISTINCT=1 npm test -- math-perf --reporter=verbose --disableConsoleIntercept)
swift Scripts/measure-math-preview.swift
```

To run the same WebKit probe on the distinct control with Node 24:

```sh
fixture=$(mktemp)
node --input-type=module -e '
  import { readFileSync } from "node:fs";
  import { distinctFormulas } from "./preview-src/test/math-perf-fixture.ts";
  process.stdout.write(distinctFormulas(readFileSync("Fixtures/math-dense-100kb.md", "utf8")));
' > "$fixture"
swift Scripts/measure-math-preview.swift App/Resources/preview/index.html "$fixture"
```
