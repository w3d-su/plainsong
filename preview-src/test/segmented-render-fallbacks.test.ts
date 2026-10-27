import { describe, expect, it } from "vitest";
import perf100 from "../../Fixtures/perf-100kb.md?raw";
import type { PreviewFileKind } from "../src/bridge";
import { SegmentedRenderer } from "../src/segmented-render";
import { expectEquivalent, finest } from "./segmented-render-helpers";

// Long or open constructs, documents that must render whole, ESM after an import and MDX
// errors: the output still equals the whole render, and the renderer does not pay a segment
// pass where only a whole render is exact (docs/decisions/2026-10-24-preview-segmented-render.md).

function sections(count: number, label = "Part"): string {
  return Array.from(
    { length: count },
    (_, index) => `## ${label} ${index}\n\nParagraph ${index} with ordinary words that fill a line the way a blog post does.`,
  ).join("\n\n");
}

/** A fence whose top-level statements are separated by blank lines, as most code is. */
function codeBlock(functions: number, closed = true): string {
  const body = Array.from(
    { length: functions },
    (_, index) => `function helper${index}(value) {\n  return value * ${index};\n}`,
  ).join("\n\n");
  return `\`\`\`js\n${body}${closed ? "\n```" : ""}`;
}

/** `text` with a paragraph typed before its last `## ` heading. */
function typedNearEnd(text: string, typed = "Typed near the end."): string {
  const end = text.lastIndexOf("\n## ");
  return `${text.slice(0, end)}\n\n${typed}\n${text.slice(end)}`;
}

async function renderTwice(kind: PreviewFileKind, text: string, context: string): Promise<SegmentedRenderer> {
  const renderer = new SegmentedRenderer(kind);
  await expectEquivalent(renderer, kind, text, `${context} first`);
  await expectEquivalent(renderer, kind, typedNearEnd(text), `${context} edited`);
  return renderer;
}

describe("segmented render fallbacks", () => {
  it.each([
    "<iframe src=\"https://example.com/embed\" />",
    "<svg><path d=\"M0\" /></svg>",
    "<script>{\"run()\"}</script>",
    "<style>{\"p { color: red }\"}</style>",
    "<foo />",
  ])("joins a segment the MDX pipeline drops entirely, %s, like the whole render", async (dropped) => {
    const renderer = new SegmentedRenderer("mdx", finest);
    await expectEquivalent(renderer, "mdx", `First paragraph.\n\n${dropped}\n\nSecond paragraph.\n`, dropped);
    expect(renderer.assembledSegmentCount).toBe(3);
  });

  it.each([
    ["md", "a fence with blank lines", (rest: string) => `${sections(30)}\n\n${codeBlock(60)}\n\n${rest}\n`],
    ["md", "an HTML comment with blank lines", (rest: string) => `${sections(30)}\n\n<!--\n${sections(40, "Hidden")}\n-->\n\n${rest}\n`],
    ["mdx", "an MDX element that wraps sections", (rest: string) => `# Title\n\n<Steps>\n\n${sections(60, "Step")}\n\n</Steps>\n\n${rest}\n`],
    ["mdx", "a fence with blank lines", (rest: string) => `${sections(30)}\n\n${codeBlock(60)}\n\n${rest}\n`],
  ] as const)("%s: keeps cutting after %s", async (kind, _label, build) => {
    const rest = sections(300);
    const baseline = await renderTwice(kind, `${sections(30)}\n\n${rest}\n`, "baseline");
    const renderer = await renderTwice(kind, build(rest), "long construct");
    // Before, five open cuts made the rest of the document one segment (or, before any cut,
    // the whole document): an edit near the end re-rendered all of it.
    expect(renderer.assembledSegmentCount).toBeGreaterThanOrEqual(baseline.assembledSegmentCount - 1);
    expect(renderer.renderedSegmentCount).toBeLessThanOrEqual(2);
  });

  it("tries one cut inside a fence left open to the end, then renders the rest as one segment", async () => {
    const renderer = new SegmentedRenderer("md");
    const text = `${sections(60)}\n\n${codeBlock(80, false)}\n\n${sections(60)}\n`;
    await expectEquivalent(renderer, "md", text, "open fence");
    expect(renderer.renderedSegmentCount - renderer.assembledSegmentCount).toBeLessThanOrEqual(1);
  });

  it("renders a document with a definition whole, without a segment pass", async () => {
    const renderer = new SegmentedRenderer("md");
    const text = `${perf100}\n[ref]: https://example.com\n`;
    await expectEquivalent(renderer, "md", text, "definition");
    expect([renderer.renderedSegmentCount, renderer.assembledSegmentCount]).toEqual([0, 0]);
    await expectEquivalent(renderer, "md", typedNearEnd(text), "definition, edited");
    expect([renderer.renderedSegmentCount, renderer.assembledSegmentCount]).toEqual([0, 0]);

    // Without the definition's line, the next render segments again.
    await expectEquivalent(renderer, "md", perf100, "definition removed");
    expect(renderer.assembledSegmentCount).toBeGreaterThan(10);
  });

  it("segments the first render of a document without definition-like lines after one with a definition", async () => {
    const renderer = new SegmentedRenderer("md");
    await expectEquivalent(renderer, "md", `${perf100}\n[ref]: https://example.com\n`, "with definition");
    expect(renderer.assembledSegmentCount).toBe(0);
    await expectEquivalent(renderer, "md", perf100, "another document");
    expect(renderer.assembledSegmentCount).toBeGreaterThan(10);
  });

  it("segments after a definition-like line that is not a definition", async () => {
    const renderer = new SegmentedRenderer("md");
    const text = `${sections(40)}\n\n\`\`\`ts\ninterface Bag {\n  [key: string]: unknown;\n}\n\`\`\`\n\n${sections(40)}\n`;
    await expectEquivalent(renderer, "md", text, "index signature");
    expect(renderer.assembledSegmentCount).toBe(0);
    await expectEquivalent(renderer, "md", typedNearEnd(text), "index signature, edited");
    expect(renderer.assembledSegmentCount).toBeGreaterThan(1);
  });

  it("stays whole after a segment pass finds a definition the line check misses", async () => {
    const renderer = new SegmentedRenderer("md");
    const text = `${sections(60)}\n\nSee [the\nlabel].\n\n[the\nlabel]: https://example.com\n`;
    await expectEquivalent(renderer, "md", text, "multi-line label");
    await expectEquivalent(renderer, "md", typedNearEnd(text), "multi-line label, edited");
    expect([renderer.renderedSegmentCount, renderer.assembledSegmentCount]).toEqual([0, 0]);
  });

  it.each([
    ["an export after the import", "export const meta = { title: \"x\" }"],
    ["a re-export of the import", "export { Button }"],
    ["a repeated import", "import Button from \"./Other\""],
  ])("merges segments for %s instead of rendering whole", async (label, esm) => {
    const text = `import Button from "./Button"\n\n${sections(40)}\n\n${esm}\n\n${sections(200)}\n`;
    const renderer = await renderTwice("mdx", text, label);
    if (!esm.startsWith("import")) {
      expect(renderer.assembledSegmentCount).toBeGreaterThan(1);
      expect(renderer.renderedSegmentCount).toBeLessThanOrEqual(2);
    }
  });

  it("renders an MDX document that does not parse whole until it parses", async () => {
    const renderer = new SegmentedRenderer("mdx");
    const before = sections(100);
    const after = sections(100);
    for (const typed of ["<Card>\n\nT", "<Card>\n\nTy", "<Card>\n\nTyp"]) {
      await expectEquivalent(renderer, "mdx", `${before}\n\n${typed}\n\n${after}\n`, typed);
    }
    // Only the first unclosed render segments up to the element; later ones go straight to
    // the whole render.
    expect(renderer.renderedSegmentCount).toBe(0);

    const closed = `${before}\n\n<Card>\n\nTyped\n\n</Card>\n\n${after}\n`;
    await expectEquivalent(renderer, "mdx", closed, "closed");
    expect(renderer.assembledSegmentCount).toBe(0);
    await expectEquivalent(renderer, "mdx", typedNearEnd(closed), "closed, edited");
    expect(renderer.assembledSegmentCount).toBeGreaterThan(1);
  });

  it("renders whole without trying later cuts after an MDX error inside a segment", async () => {
    const renderer = new SegmentedRenderer("mdx");
    const text = `${sections(100)}\n\n</Stray>\n\n${sections(200)}\n`;
    await expectEquivalent(renderer, "mdx", text, "stray closing tag");
    // The segments before the error and the one that holds it: no tries past it.
    expect(renderer.renderedSegmentCount).toBeLessThanOrEqual(5);
  });
});
