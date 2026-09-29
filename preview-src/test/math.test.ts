import { VFile } from "vfile";
import { describe, expect, it, vi } from "vitest";
import mathFixture from "../../Fixtures/math.md?raw";
import mathEdgeCases from "../../Fixtures/math-edge-cases.md?raw";
import { rehypeMathDiagnostics } from "../src/math";
import type { TreeNode } from "../src/mdx-placeholders";
import { renderMarkdown, renderMdx } from "../src/pipeline";

describe("math preview", () => {
  it("renders the math fixture through both pipelines", async () => {
    for (const render of [renderMarkdown, renderMdx]) {
      const html = await render(mathFixture);

      // Display blocks: $$ paragraphs and the ```math fence share one wrapper.
      expect(html.match(/class="plainsong-math-block"/g)).toHaveLength(6);
      expect(html).toContain('class="katex-display"');
      // The latex fence and inline code stay literal code.
      expect(html).toContain('<code class="language-latex">');
      expect(html).toContain("<code>$x$</code>");
      // MathML stays for assistive technology.
      expect(html).toContain('encoding="application/x-tex"');
    }
  });

  it("keeps data-line and data-line-end on display math wrappers", async () => {
    const html = await renderMarkdown(
      "Before\n\n$$\na^2 + b^2 = c^2\n$$\n\nAfter\n\n```math\nx^2\n```\n",
    );

    expect(html).toContain(
      '<div class="plainsong-math-block" data-math-index="0" data-line="3" data-line-end="5">',
    );
    expect(html).toContain(
      '<div class="plainsong-math-block" data-math-index="1" data-line="9" data-line-end="11">',
    );
    expect(html).toContain('<p data-line="1">Before</p>');
    expect(html).toContain('<p data-line="7">After</p>');
  });

  it("keeps anchors on adjacent and boundary display math", async () => {
    const html = await renderMarkdown(
      "$$\na\n$$\n\n$$\nb\n$$\n",
    );

    expect(html).toContain('data-line="1" data-line-end="3"');
    expect(html).toContain('data-line="5" data-line-end="7"');
  });

  it("locates hand-written math inside lists and quotes", async () => {
    const html = await renderMarkdown(
      "- item\n\n  $$\n  x^2\n  $$\n\n> $$\n> y^2\n> $$\n\ntail\n",
    );

    expect(html).toContain('data-line="3" data-line-end="5"');
    expect(html).toContain('data-line="7" data-line-end="9"');
    expect(html).toContain('<p data-line="11">tail</p>');
  });

  it("keeps inline math inside its paragraph anchor", async () => {
    const html = await renderMarkdown("Inline $E = mc^2$ math.\n");

    expect(html).not.toContain("plainsong-math-block");
    expect(html).toContain(
      '<p data-line="1">Inline <span class="plainsong-math-inline" data-math-index="0" data-line="1"><span class="katex">',
    );
  });

  it("shows selectable source and a text hint for broken math", async () => {
    const html = await renderMarkdown("Bad $\\frac{1}$ inline.\n\n$$\n\\frac{1}\n$$\n");

    // Both errors keep the literal source and gain a non-hover text hint.
    expect(html.match(/class="katex-error"/g)).toHaveLength(2);
    expect(html.match(/class="math-error-hint"/g)).toHaveLength(2);
    expect(html).toContain("KaTeX: Unexpected end of input");
    expect(html).toContain("\\frac{1}");
    // The display error stays inside its line-anchored wrapper.
    expect(html).toContain(
      '<div class="plainsong-math-block" data-math-index="1" data-line="3" data-line-end="5">',
    );
  });

  it("shows a text hint for unknown commands that render as red text", async () => {
    for (const render of [renderMarkdown, renderMdx]) {
      const html = await render(
        "bad $\\notACommand{x}$ then $x$.\n\n$$\n\\notACommand{y}\n$$\n",
      );

      // Unknown commands throw inside KaTeX and re-render as red markup with
      // no `.katex-error` element; diagnostics pair via the math wrapper's
      // source position instead of an error element or title text.
      expect(html).not.toContain("katex-error");
      expect(html.match(/class="math-error-hint"/g)).toHaveLength(2);
      expect(html).toContain("KaTeX: Undefined control sequence: \\notACommand");
      // The hint lands inside the failing formulas' wrappers, not the good one.
      expect(html).toContain(
        'class="plainsong-math-inline" data-math-index="0"',
      );
      expect(html).toContain(
        '<div class="plainsong-math-block" data-math-index="2" data-line="3" data-line-end="5">',
      );
      expect(html).toMatch(
        /math-index="1"[^>]*><span class="katex">/,
      );
    }
  });

  it("trims KaTeX position suffix and underline marks from hints", async () => {
    for (const render of [renderMarkdown, renderMdx]) {
      const html = await render(
        "bad $\\foo$ here.\n\n```math\n\\foo\n```\n",
      );
      const hints = [
        ...html.matchAll(/<span class="math-error-hint"[^>]*>([^<]*)<\/span>/g),
      ].map((match) => match[1]);

      expect(hints).toHaveLength(2);
      for (const hint of hints) {
        expect(hint).toBe("KaTeX: Undefined control sequence: \\foo");
        expect(hint).not.toContain("̲");
        expect(hint).not.toContain(" at position ");
      }
      expect(html).not.toContain("̲");
    }
  });

  it("keeps math diagnostics local to the failing formula", async () => {
    const html = await renderMarkdown(
      "$$\n\\frac{1\n$$\n\nGood $a^2$ text.\n",
    );

    expect(html).toContain("katex-error");
    expect(html).toContain(
      '<p data-line="5">Good <span class="plainsong-math-inline"',
    );
  });

  it("renders strict-mode LaTeX incompatibilities without console noise", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      for (const render of [renderMarkdown, renderMdx]) {
        const html = await render("中文 $速度 = v$ 公式\n");
        expect(html).toContain('<span class="katex">');
        expect(html).not.toContain("math-error-hint");
      }
      expect(warn).not.toHaveBeenCalled();
    } finally {
      warn.mockRestore();
    }
  });

  it("pairs unplaced diagnostics with their own formula, once each", () => {
    const errorA = new Error("KaTeX parse error: Alpha broke");
    const errorB = new Error("KaTeX parse error: Beta broke");
    const wrapper = (index: number, error: Error | undefined): TreeNode => ({
      type: "element",
      tagName: "span",
      properties: { className: ["plainsong-math-inline"], dataMathIndex: String(index) },
      children: [
        {
          type: "element",
          tagName: "span",
          properties: { className: ["katex-error"], title: String(error ?? "unknown") },
          children: [{ type: "text", value: "src" }],
        },
      ],
    });
    const tree: TreeNode = {
      type: "root",
      children: [
        {
          type: "element",
          tagName: "p",
          properties: {},
          children: [wrapper(0, errorB), wrapper(1, errorA), wrapper(2, undefined)],
        },
      ],
    };
    const file = new VFile();
    for (const cause of [errorA, errorB]) {
      file.message("Could not render math with KaTeX", { cause, source: "rehype-katex" });
    }

    rehypeMathDiagnostics()(tree, file);

    const hints = (tree.children?.[0].children ?? []).map((node) => {
      const hint = node.children?.at(-1);
      return hint?.properties?.className ? hint.children?.[0].value : undefined;
    });
    expect(hints).toEqual([
      "KaTeX: Beta broke",
      "KaTeX: Alpha broke",
      "KaTeX could not render this formula",
    ]);
  });

  it("rejects untrusted KaTeX directives", async () => {
    const html = await renderMarkdown(
      String.raw`Safe $a^2$ and $\href{https://example.invalid}{x}$ and $\includegraphics{evil}$.`,
    );

    expect(html).toContain('<span class="katex">');
    // trust:false renders untrusted commands as colored text — never as DOM.
    expect(html).not.toContain("<a ");
    expect(html).not.toContain("<img");
    expect(html).not.toContain("href=");
  });

  it("preserves currency escapes and literal dollars", async () => {
    const html = await renderMarkdown(
      "Escaped \\$5 and \\$10 stay text.\n\nUnclosed $x + 1 stays literal.\n",
    );

    expect(html).toContain("<p data-line=\"1\">Escaped $5 and $10 stay text.</p>");
    expect(html).toContain("Unclosed $x + 1 stays literal.");
    expect(html).not.toContain("katex");
  });

  it("documents the bare-dollar currency behavior", async () => {
    const html = await renderMarkdown("Price $5 and $10 done.\n");

    // Known compatibility behavior: bare $…$ is math; escape with \$ for money.
    expect(html).toContain('encoding="application/x-tex">5 and </annotation>');
  });

  it("renders the edge-case fixture through both pipelines", async () => {
    for (const render of [renderMarkdown, renderMdx]) {
      const html = await render(mathEdgeCases);
      expect(html).toContain("katex-error");
      expect(html).toContain("math-error-hint");
      expect(html.match(/class="plainsong-math-block"/g)).toHaveLength(3);
    }
  });
});
