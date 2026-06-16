import { describe, expect, it } from "vitest";
import kitchenSink from "../../Fixtures/kitchen-sink.md?raw";
import kitchenSinkMdx from "../../Fixtures/kitchen-sink.mdx?raw";
import mdxSyntaxError from "../../Fixtures/mdx-syntax-error.mdx?raw";
import { mdxErrorBannerHtml } from "../src/mdx-error";
import { renderMarkdown, renderMdx } from "../src/pipeline";

describe("markdown preview pipeline", () => {
  it("renders the kitchen sink fixture", async () => {
    await expect(renderMarkdown(kitchenSink)).resolves.toMatchSnapshot();
  });

  it("adds data-line attributes to block elements", async () => {
    const html = await renderMarkdown("# Title\n\nParagraph\n\n- [ ] Task\n");

    expect(html).toContain('<h1 data-line="1">Title</h1>');
    expect(html).toContain('<p data-line="3">Paragraph</p>');
    expect(html).toContain('data-line="5"');
  });
});

describe("mdx preview pipeline", () => {
  it("renders the MDX kitchen sink fixture", async () => {
    await expect(renderMdx(kitchenSinkMdx)).resolves.toMatchSnapshot();
  });

  it("renders MDX syntax as non-executed placeholders", async () => {
    const html = await renderMdx(`import Button from "./Button"

<Button tone="info" count={2}>
  **Child markdown**
</Button>

Inline <Badge tone="success">Ready</Badge> and {readingTime}.
`);

    expect(html).toContain("mdx-esm-placeholder");
    expect(html).toContain('⟨import Button from "./Button"⟩');
    expect(html).toContain("mdx-component-card mdx-component-card-flow");
    expect(html).toContain('<span class="mdx-component-name">Button</span>');
    expect(html).toContain('tone="info" count={2}');
    expect(html).toContain("<strong>Child markdown</strong>");
    expect(html).toContain("mdx-component-card mdx-component-card-text");
    expect(html).toContain('<span class="mdx-component-name">Badge</span>');
    expect(html).toContain('<code class="mdx-expression-chip">{readingTime}</code>');
  });

  it("renders lowercase JSX as sanitized HTML", async () => {
    const html = await renderMdx(`<div className="note" onclick="alert('x')">
  <strong>Safe</strong>
  <script>alert("nope")</script>
  <img src={"./asset.png"} onerror="alert('x')" alt="Asset" />
</div>
`);

    expect(html).toContain('<div class="note" data-line="1">');
    expect(html).toContain("<strong>Safe</strong>");
    expect(html).toContain('<img src="./asset.png" alt="Asset">');
    expect(html).not.toContain("<script");
    expect(html).not.toContain("onclick");
    expect(html).not.toContain("onerror");
  });

  it("preserves data-line attributes on MDX block elements", async () => {
    const html = await renderMdx(`# Title

<Callout>
  Body
</Callout>
`);

    expect(html).toContain('<h1 data-line="1">Title</h1>');
    expect(html).toContain('class="mdx-component-card mdx-component-card-flow" data-line="3"');
  });

  it("surfaces syntax errors without blanking and recovers after a fix", async () => {
    const lastGood = await renderMdx("# Good\n\n<Callout>Still visible</Callout>\n");
    let banner = "";

    try {
      await renderMdx(mdxSyntaxError);
    } catch (error) {
      banner = mdxErrorBannerHtml(error);
    }

    expect(banner).toContain("MDX syntax error on line");
    expect(`${banner}${lastGood}`).toContain("<h1");
    expect(`${banner}${lastGood}`).toContain("Good");

    const fixed = `${mdxSyntaxError}\n</Callout>\n`;
    await expect(renderMdx(fixed)).resolves.toContain("mdx-component-card");
  });

  it("does not execute scripts or MDX expressions", async () => {
    const marker = "__plainsongMdxExecuted";
    (globalThis as Record<string, unknown>)[marker] = false;

    const html = await renderMdx(`<div>
  {globalThis.${marker} = true}
  <script>globalThis.${marker} = true</script>
</div>
`);

    expect((globalThis as Record<string, unknown>)[marker]).toBe(false);
    expect(html).toContain(`{globalThis.${marker} = true}`);
    expect(html).not.toContain("<script");
  });
});
