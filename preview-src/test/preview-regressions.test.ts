import { beforeEach, describe, expect, it, vi } from "vitest";
import type { BridgeMessage, RenderPayload } from "../src/bridge";
import { renderMarkdown, renderMdx } from "../src/pipeline";

vi.mock("mermaid", () => ({ default: { initialize: vi.fn(), render: vi.fn() } }));
let messages: BridgeMessage[];
const scrollIntoView = vi.fn();
beforeEach(async () => {
  vi.resetModules();
  messages = [];
  scrollIntoView.mockReset();
  HTMLElement.prototype.scrollIntoView = scrollIntoView;
  document.body.innerHTML = '<main id="preview-root"></main>';
  window.webkit = { messageHandlers: { bridge: { postMessage: (message) => messages.push(message) } } };
  await import("../src/index");
});

async function render(renderID: number, text: string, assetRootID = "root-a", fileKind: "md" | "mdx" = "md") {
  const payload: RenderPayload = {
    renderID, version: 0, text, fileKind, assetRootID, baseDir: null,
    theme: "light", allowRemoteImages: false,
  };
  window.PlainsongBridge.receive({ name: "render", payload });
  await vi.waitFor(() => expect(messages.some((message) =>
    message.name === "renderComplete" && message.payload.renderID === renderID,
  )).toBe(true));
}

describe("preview review regressions", () => {
  it("changes local asset URLs only when their root changes and retains the displayed root on MDX errors", async () => {
    await render(1, "# A\n\n![](image.png)");
    const original = document.querySelector("img")!;
    const firstURL = original.src;
    await render(2, "# A\n\n![](image.png)\n\nEdit");
    expect(document.querySelector("img")).toBe(original);
    expect(original.src).toBe(firstURL);
    await render(3, "# B\n\n![](image.png)", "root-b");
    const secondURL = document.querySelector("img")!.src;
    expect(secondURL).not.toBe(firstURL);
    expect(new URL(secondURL).searchParams.get("plainsong-root")).toBe("root-b");
    await render(4, "<Component", "root-c", "mdx");
    window.PlainsongBridge.receive({ name: "setTheme", payload: { theme: "dark", allowRemoteImages: false } });
    expect(document.querySelector("img")!.src).toBe(secondURL);
  });

  it("navigates hash clicks locally with encoded Unicode and duplicate headings", async () => {
    await render(1, "[jump](#target) [again](#target-1) [中文](#%E4%B8%AD%E6%96%87) [bad](#%ZZ)\n\n# Target\n\n# Target\n\n# 中文");
    for (const [index, slug] of [[0, "target"], [1, "target-1"], [2, "中文"]] as const) {
      const target = document.getElementById("plainsong-heading-" + slug)!;
      document.querySelectorAll<HTMLAnchorElement>("a")[index].click();
      expect(scrollIntoView.mock.instances.at(-1)).toBe(target);
    }
    document.querySelectorAll<HTMLAnchorElement>("a")[3].click();
    expect(messages.filter((message) => message.name === "linkClicked")).toEqual([]);
    expect(scrollIntoView).toHaveBeenCalledTimes(3);
  });

  it("continues to forward file links to Swift", async () => {
    await render(1, "[file](other.md)");
    document.querySelector<HTMLAnchorElement>("a")!.click();
    expect(messages.at(-1)).toEqual({ name: "linkClicked", payload: { href: "other.md" } });
  });

  it("keeps explicit sanitized MDX targets and Markdown footnote links navigable", async () => {
    await render(1, '[custom](#destination)\n\n<h2 id="destination">Named</h2>', "root-a", "mdx");
    const heading = document.querySelector("h2")!;
    expect(heading.id).toBe("user-content-destination");
    document.querySelector<HTMLAnchorElement>("a")!.click();
    expect(scrollIntoView.mock.instances.at(-1)).toBe(heading);
    await render(2, "Footnote[^1]\n\n[^1]: Note");
    const footnote = document.querySelector<HTMLAnchorElement>("a[data-footnote-ref]")!;
    const target = document.getElementById(footnote.hash.slice(1));
    expect(target).not.toBeNull();
    footnote.click();
    expect(scrollIntoView.mock.instances.at(-1)).toBe(target);
    expect(messages.some((message) => message.name === "linkClicked")).toBe(false);
  });

  it("gives both pipelines deterministic safe heading IDs without duplicate suffix collisions", async () => {
    for (const processor of [renderMarkdown, renderMdx]) {
      const root = document.createElement("main");
      root.innerHTML = await processor("# Target\n\n# Target\n\n# Target-1\n\n## **中文** `code`\n\n# location");
      const ids = [...root.querySelectorAll("h1,h2")].map((heading) => heading.id);
      expect(ids).toEqual(["plainsong-heading-target", "plainsong-heading-target-1", "plainsong-heading-target-1-1", "plainsong-heading-中文-code", "plainsong-heading-location"]);
      expect(new Set(ids).size).toBe(ids.length);
    }
  });

  it("preserves trusted KaTeX layout while rejecting authored styles, scripts and SVG", async () => {
    const math = String.raw`$\frac{1}{2}$ and $\widehat{abc}$`;
    const md = document.createElement("main");
    md.innerHTML = await renderMarkdown(math);
    const mdx = document.createElement("main");
    mdx.innerHTML = await renderMdx(math + '\n\n<div style="position:fixed"><span style="color:red">Safe</span><script>bad()</script><svg><path>payload</path></svg></div>');
    expect(mdx.querySelectorAll(".katex").length).toBe(2);
    expect([...mdx.querySelectorAll(".katex [style]")].map((node) => node.getAttribute("style")))
      .toEqual([...md.querySelectorAll(".katex [style]")].map((node) => node.getAttribute("style")));
    expect(mdx.querySelectorAll(".katex [style]").length).toBeGreaterThan(0);
    expect(mdx.querySelector(".katex svg")).not.toBeNull();
    expect(mdx.querySelector("div[style], div > span[style], script, div > svg")).toBeNull();
    expect(mdx.textContent).not.toContain("payload");
    expect(mdx.textContent).not.toContain("bad()");
  });
});
