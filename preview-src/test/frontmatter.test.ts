import remarkFrontmatter from "remark-frontmatter";
import remarkParse from "remark-parse";
import { unified } from "unified";
import { describe, expect, it } from "vitest";
import { hasClosedFrontmatter, remarkClosedFrontmatter } from "../src/frontmatter";
import { renderMarkdown, renderMdx } from "../src/pipeline";

const unclosedOpener = "---\n# Title\n\n- a\n- b\n\n> quote\n";

const plain = unified().use(remarkParse);
const frontmatter = unified().use(remarkParse).use(remarkFrontmatter, ["yaml"]);
const gated = unified().use(remarkParse).use(remarkClosedFrontmatter);

describe("closed frontmatter gate", () => {
  it.each([
    "---\ntitle: a\n---\n\n- b\n",
    "---\ntitle: a\n---",
    "---\n---\n",
    "---\n---",
    "---\n\n\n---\n> q\n",
    "---\r\ntitle: a\r\n---\r\n- b\r\n",
    "---\rtitle: a\r---\r- b\r",
    "--- \t\ntitle: a\n---  \n- b\n",
    "\uFEFF---\ntitle: a\n---\n- b\n",
    "---\ntags:\n  - a\n  - b\n---\n- c\n",
    unclosedOpener,
    "---\n",
    "---",
    "---\ntitle: a\n",
    "---\ntitle: a\n...\n- b\n",
    "----\ntitle: a\n----\n- b\n",
    " ---\ntitle: a\n---\n- b\n",
    "---\ntitle: a\n ---\n- b\n",
    "---\ntitle: a\n--- x\n- b\n",
    "--- x\ntitle: a\n---\n- b\n",
    "# x\n---\ntitle: a\n---\n- b\n",
    "+++\ntitle = 1\n+++\n- b\n",
  ])("parses %j like remark-frontmatter when closed, else like plain remark", (document) => {
    const reference = frontmatter.parse(document);
    const closed = reference.children[0]?.type === "yaml";

    expect(hasClosedFrontmatter(document)).toBe(closed);
    expect(gated.parse(document)).toEqual(closed ? reference : plain.parse(document));
  });
});

describe("leading frontmatter fence", () => {
  it.each([
    ["md", renderMarkdown],
    ["mdx", renderMdx],
  ])("renders an unclosed opener as a thematic break and keeps containers (%s)", async (_, render) => {
    const html = await render(unclosedOpener);

    expect(html).toContain('<hr data-line="1">');
    expect(html).toContain('<h1 id="plainsong-heading-title" data-line="2">Title</h1>');
    expect(html).toContain('<ul data-line="4">');
    expect(html).toContain('<li data-line="4">a</li>');
    expect(html).toContain('<blockquote data-line="7">');
    expect(html).not.toContain("<p data-line=\"4\">");
  });

  it.each([
    ["md", renderMarkdown],
    ["mdx", renderMdx],
  ])("strips a closed block and keeps containers after it (%s)", async (_, render) => {
    const html = await render("---\ntitle: Post\ntags:\n  - a\n---\n\n- b\n\n> quote\n");

    expect(html).not.toContain("title: Post");
    expect(html).not.toContain("<hr");
    expect(html).toContain('<ul data-line="7">');
    expect(html).toContain('<blockquote data-line="9">');
  });
});
