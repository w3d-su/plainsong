import { describe, expect, it } from "vitest";
import kitchenSink from "../../Fixtures/kitchen-sink.md?raw";
import { renderMarkdown } from "../src/pipeline";

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
