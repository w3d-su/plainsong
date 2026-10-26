import { describe, expect, it } from "vitest";
import kitchenSink from "../../Fixtures/kitchen-sink.md?raw";
import kitchenSinkMdx from "../../Fixtures/kitchen-sink.mdx?raw";
import mathDense from "../../Fixtures/math-dense-100kb.md?raw";
import mdxSyntaxError from "../../Fixtures/mdx-syntax-error.mdx?raw";
import perf100 from "../../Fixtures/perf-100kb.md?raw";
import type { PreviewFileKind } from "../src/bridge";
import { renderMarkdown, renderMdx } from "../src/pipeline";
import { type SegmentLimits, SegmentedRenderer } from "../src/segmented-render";

// The segmented renderer must return exactly what a whole-document render returns
// (docs/decisions/2026-10-24-preview-segmented-render.md). `finest` tries every possible
// cut, so a test document of a few hundred bytes is cut wherever the rules allow.
const finest: SegmentLimits = {
  minimumLength: 0,
  maximumLength: 0,
  cutHashModulus: 1,
  maximumRejectedCuts: 1_000,
};
const coarse: SegmentLimits = {
  minimumLength: 40,
  maximumLength: 400,
  cutHashModulus: 3,
  maximumRejectedCuts: 2,
};

// PLAINSONG_SEGMENT_SOAK=<n> multiplies the randomized runs for a local soak.
const soak = Number(
  (globalThis as { process?: { env: Record<string, string | undefined> } }).process?.env
    .PLAINSONG_SEGMENT_SOAK ?? "1",
);

async function whole(kind: PreviewFileKind, text: string): Promise<string> {
  return kind === "md" ? renderMarkdown(text) : renderMdx(text);
}

async function outcome(render: () => Promise<string>): Promise<string> {
  try {
    return await render();
  } catch (error) {
    return `THROWS ${(error as Error).message}`;
  }
}

async function expectEquivalent(
  renderer: SegmentedRenderer,
  kind: PreviewFileKind,
  text: string,
  context: string,
): Promise<void> {
  const expected = await outcome(() => whole(kind, text));
  const actual = await outcome(() => renderer.render(text));
  if (actual !== expected) {
    throw new Error(`${context}\n--- document ---\n${JSON.stringify(text)}\n--- whole ---\n${expected}\n--- segmented ---\n${actual}`);
  }
}

function random(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

const markdownBlocks = [
  "# Intro",
  "# Intro",
  "## Intro-1",
  "#",
  "Plain paragraph with *emphasis*, `code`, [a link](./a.md) and $x^2$.",
  "Two line\nparagraph with a lazy\ncontinuation",
  "Setext heading\n===",
  "Setext two\n---",
  "- one\n- two\n  - nested",
  "- loose\n\n- list\n\n  continued paragraph",
  "* star item",
  "+ plus item",
  "1. first\n2. second",
  "3) paren item",
  "- [ ] task\n- [x] done",
  "> quote\n> more",
  "> - quoted list\n>\n> after",
  ">> nested quote",
  "```js\nconst a = 1;\n\nconst b = 2;\n```",
  "~~~\ntilde fence\n\n~~~",
  "```mermaid\ngraph TD\n  A --> B\n```",
  "```\nunclosed fence",
  "````\nlong fence\n```\nstill code\n````",
  "   ```\nindented fence\n   ```",
  "- item\n  ```\n  fenced in list\n\n  ```",
  "    indented code\n\n    more code",
  "$$\n\\frac{a}{b}\n$$",
  "$$\n\\frac{a}{\n$$",
  "$$\nunclosed math",
  "Inline $\\frac{1}{$ broken",
  "| a | b |\n|---|--:|\n| 1 | 2 |",
  "***",
  "___",
  "<div>\nhtml block\n</div>",
  "<!--\ncomment with\n\nblank line\n-->",
  "<!-- unclosed comment",
  "<pre>\npre block\n\nwith blank\n</pre>",
  "<script>\nlet x = 1;\n\n</script>",
  "2026 was a year.",
  "3.14 is pi",
  "10) ten",
  "Hard break  \nnext line",
  "Text with \\* escaped star",
  "![image](./img.png \"title\")",
  "Autolink https://example.com and <https://example.org>",
  "Heading text again\n\n# Intro",
  "﻿bom line",
  "   \t",
  "&#x0;L5&#x0; literal marker text",
  "Footnote call[^1].",
  "Reference [ref] and [text][ref].",
];

const definitionBlocks = ["[ref]: https://example.com \"Title\"", "[^1]: The footnote.\n\n    Continued."];

const mdxBlocks = [
  "import Button from \"./Button\"",
  "export const meta = {\n  title: \"x\",\n\n  tags: [\"a\"],\n}",
  "export const one = 1",
  "<Card tone=\"info\">\n\n# Inside card\n\nText in card.\n\n</Card>",
  "<Card>\n  **inline child**\n</Card>",
  "<Hr />",
  "<div className=\"note\" data-line=\"99\">\n  <span data-line=\"7\">user line</span>\n</div>",
  "Inline <Badge>new</Badge> and {readingTime}.",
  "{1 + 1}",
  "{\n  multiLine,\n\n  expression\n}",
];

// Each makes the whole MDX document fail to parse.
const mdxErrorBlocks = ["<Unclosed>", "</Stray>", "{ unbalanced", "<https://example.org>"];

const insertions = [
  "\n", "\n\n", "\n\n\n", " ", "x", "`", "```", "~~~", "$", "$$", "-", "- ", "* ", "+ ", "1. ",
  "#", "# ", "> ", "<", ">", "|", "[", "]", "(", ")", "{", "}", "---", "===", "\t", "    ",
  "[ref]", "[^1]", "<!--", "-->", "<div>", "</div>", "\\", "*", "_", "1)", "\r\n", "﻿",
];

// Markdown blocks that are also valid MDX (MDX reads `<` and `{` as JSX and expressions).
const mdxSafeMarkdownBlocks = markdownBlocks.filter((block) => !/[<{]/u.test(block));

function generateDocument(next: () => number, kind: PreviewFileKind, seed: number): string {
  const withDefinitions = seed % 4 === 0;
  const pool = kind === "md"
    ? markdownBlocks
    : [...mdxSafeMarkdownBlocks, ...mdxBlocks, ...(seed % 6 === 0 ? mdxErrorBlocks : [])];
  const blocks: string[] = [];
  if (next() < 0.2) blocks.push("---\ntitle: Front\n\ntags: [a]\n---");
  const count = 4 + Math.floor(next() * 14);
  for (let index = 0; index < count; index += 1) {
    if (withDefinitions && next() < 0.15) {
      blocks.push(definitionBlocks[Math.floor(next() * definitionBlocks.length)]);
    } else {
      blocks.push(pool[Math.floor(next() * pool.length)]);
    }
  }
  const separators = ["\n\n", "\n\n", "\n\n", "\n", "\n\n\n", "\n  \n"];
  let text = blocks[0];
  for (const block of blocks.slice(1)) {
    text += separators[Math.floor(next() * separators.length)] + block;
  }
  if (next() < 0.7) text += "\n";
  if (next() < 0.1) text = text.replace(/\n/gu, "\r\n");
  return text;
}

// MDX reads these as JSX or expressions; most insertions avoid them so that documents
// stay valid often enough to exercise segments (an invalid one renders whole).
const mdxSafeInsertions = insertions.filter((insertion) => !/[<{}]/u.test(insertion));

function edit(next: () => number, text: string, kind: PreviewFileKind): string {
  const position = Math.floor(next() * (text.length + 1));
  const choice = next();
  if (choice < 0.5) {
    const pool = kind === "mdx" && next() < 0.9 ? mdxSafeInsertions : insertions;
    const insertion = pool[Math.floor(next() * pool.length)];
    return text.slice(0, position) + insertion + text.slice(position);
  }
  if (choice < 0.8) {
    const length = Math.floor(next() * 12);
    return text.slice(0, position) + text.slice(position + length);
  }
  if (choice < 0.9) {
    // Paste a whole block at a line start.
    const lineStart = text.lastIndexOf("\n", position - 1) + 1;
    const pool = kind === "mdx" ? [...mdxSafeMarkdownBlocks, ...mdxBlocks] : markdownBlocks;
    return `${text.slice(0, lineStart)}${pool[Math.floor(next() * pool.length)]}\n\n${text.slice(lineStart)}`;
  }
  // Duplicate a slice elsewhere, as a cut-and-paste would.
  const length = Math.floor(next() * 40);
  const target = Math.floor(next() * (text.length + 1));
  return text.slice(0, target) + text.slice(position, position + length) + text.slice(target);
}

describe("segmented preview render", () => {
  it.each([
    ["kitchen-sink.md", "md", kitchenSink],
    ["kitchen-sink.mdx", "mdx", kitchenSinkMdx],
    ["mdx-syntax-error.mdx", "mdx", mdxSyntaxError],
  ] as const)("matches the whole render of %s at every cut", async (name, kind, text) => {
    await expectEquivalent(new SegmentedRenderer(kind, finest), kind, text, name);
  });

  it("matches the whole render of the large fixtures with default limits", { timeout: 60_000 }, async () => {
    for (const [name, text] of [["perf-100kb.md", perf100], ["math-dense-100kb.md", mathDense]] as const) {
      const renderer = new SegmentedRenderer("md");
      await expectEquivalent(renderer, "md", text, name);
      const middle = text.indexOf("\n", text.length / 2);
      await expectEquivalent(renderer, "md", `${text.slice(0, middle)}\n\n# Intro\n${text.slice(middle)}`, `${name} edited`);
    }
  });

  it.each(["md", "mdx"] as const)("segments %s with an unclosed frontmatter opener", async (kind) => {
    const renderer = new SegmentedRenderer(kind, finest);
    const text = "---\n# Title\n\n- a\n- b\n\n> quote\n\n" +
      Array.from({ length: 20 }, (_, index) => `## Section ${index}\n\nParagraph ${index}.`).join("\n\n");
    const html = await renderer.render(text);
    expect(html).toBe(await (kind === "md" ? renderMarkdown(text) : renderMdx(text)));
    expect(html).toContain("<ul");
    expect(html).toContain("<blockquote");
    expect(renderer.assembledSegmentCount).toBeGreaterThan(1);
  });

  it.each(["md", "mdx"] as const)("does not cut %s frontmatter that follows a BOM", async (kind) => {
    // micromark skips one leading BOM before the opening fence. The blank line inside the
    // YAML sits past the default maximum segment length, so a cut there would be taken.
    const fields = Array.from({ length: 1_000 }, (_, index) => `field${index}: value ${index}`);
    const text = `\uFEFF---\n${fields.join("\n")}\n\nsummary: tail\n---\n\n# Body\n`;
    await expectEquivalent(new SegmentedRenderer(kind), kind, text, `${kind} BOM frontmatter`);
  });

  it.each(["md", "mdx"] as const)("segments %s with closed or unclosed leading fences", async (kind) => {
    // remarkClosedFrontmatter decides per parsed text, so only the first segment may read
    // frontmatter, and only with its closing fence inside it. A later `---` thematic break,
    // followed by another `---`, must not open frontmatter in the segment that holds it.
    // An unclosed opener has no later `---` line at all (one would close it).
    const body = (rule: string) =>
      `Intro paragraph.\n\n- item\n\n> quote\n\nMiddle paragraph.\n\n${rule}\n\nAfter the rule.\n\n${rule}\n\n# Tail\n`;
    for (const bom of ["", "\uFEFF"]) {
      for (const [label, head, rule] of [
        ["closed", "---\ntitle: x\n\ntags: y\n---\n\n", "---"],
        ["unclosed", "---\n\ntitle: x\n\n", "***"],
      ] as const) {
        const renderer = new SegmentedRenderer(kind, finest);
        const text = bom + head + body(rule);
        await expectEquivalent(renderer, kind, text, `${kind} ${label} ${bom ? "BOM " : ""}leading fence`);
        expect(renderer.assembledSegmentCount).toBeGreaterThan(1);
        const html = await renderer.render(text);
        expect(html).toContain("<li");
        expect(html).toContain("<blockquote");
        expect(html.includes("title: x")).toBe(label === "unclosed");
      }
    }
  });

  it("reuses unchanged segments", async () => {
    const renderer = new SegmentedRenderer("md", finest);
    const blocks = Array.from({ length: 40 }, (_, index) => `## Section ${index}\n\nParagraph ${index}.`);
    await renderer.render(blocks.join("\n\n"));
    blocks[20] += " Edited.";
    await expectEquivalent(renderer, "md", blocks.join("\n\n"), "edited");
    expect(renderer.renderedSegmentCount).toBe(1);
  });

  it("keeps line numbers, math indices and duplicate heading IDs global", async () => {
    const renderer = new SegmentedRenderer("md", finest);
    const text = "# Same\n\n$a$\n\n# Same\n\n$$\nb\n$$\n\n# Same\n";
    const html = await renderer.render(text);
    expect(html).toBe(await renderMarkdown(text));
    expect(html).toContain('id="plainsong-heading-same-2" data-line="11"');
    expect(html).toContain('data-math-index="1" data-line="7" data-line-end="9"');
  });

  for (const kind of ["md", "mdx"] as const) {
    for (const [label, limits, floor] of [["finest", finest, 0.3], ["coarse", coarse, 0.1]] as const) {
      it(`matches the whole render through random ${kind} edits (${label} cuts)`, { timeout: 120_000 }, async () => {
        const documents = 24 * soak;
        let renders = 0;
        let segmented = 0;
        let segments = 0;
        for (let seed = 1; seed <= documents; seed += 1) {
          const next = random(seed * 7_919 + (kind === "mdx" ? 1 : 0) + (label === "coarse" ? 2 : 0));
          const renderer = new SegmentedRenderer(kind, limits);
          let text = generateDocument(next, kind, seed);
          await expectEquivalent(renderer, kind, text, `seed ${seed} initial`);
          for (let step = 1; step <= 24; step += 1) {
            text = edit(next, text, kind);
            await expectEquivalent(renderer, kind, text, `seed ${seed} step ${step}`);
            renders += 1;
            segmented += renderer.assembledSegmentCount > 0 ? 1 : 0;
            segments += renderer.assembledSegmentCount;
          }
        }
        console.log(`${kind} ${label}: ${segmented}/${renders} renders segmented, ${(segments / Math.max(segmented, 1)).toFixed(1)} segments each`);
        // Guard against the comparison passing only because everything fell back.
        expect(segmented / renders).toBeGreaterThan(floor);
      });
    }
  }
});
