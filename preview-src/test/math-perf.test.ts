import { describe, it } from "vitest";
import mathDenseFixture from "../../Fixtures/math-dense-100kb.md?raw";
import { renderMarkdown, renderMdx } from "../src/pipeline";

// Informational only: records pipeline render time for the named math-dense
// fixture (docs/perf-log.md). The 100 ms preview budget is a settled-update
// WebKit gate owned by PerformanceTests; this JSDOM number is not that gate.
describe("math preview performance (informational)", () => {
  it("measures render time for Fixtures/math-dense-100kb.md", { timeout: 30_000 }, async () => {
    for (const [name, render] of [
      ["markdown", renderMarkdown],
      ["mdx", renderMdx],
    ] as const) {
      await render(mathDenseFixture); // warm the parser/katex paths
      const samples: number[] = [];
      for (let i = 0; i < 3; i += 1) {
        const start = performance.now();
        await render(mathDenseFixture);
        samples.push(performance.now() - start);
      }
      const median = [...samples].sort((a, b) => a - b)[1];
      console.log(
        `MATH PERF ${name} 100KB median ${median.toFixed(3)} ms samples [${samples
          .map((s) => s.toFixed(3))
          .join(", ")}]`,
      );
    }
  });
});
