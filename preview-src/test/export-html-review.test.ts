import { afterEach, describe, expect, it, vi } from "vitest";
import type { ExportHTMLHost } from "../src/export-html";
import type { ExportHTMLPayload, ExportHTMLResultPayload } from "../src/bridge";
import {
  buildStaticExportHTML, collectImageResources, collectPreviewStyleText,
  handleExportHTML, resetExportHTMLSession, sanitizeStaticClone,
} from "../src/export-html";
import { imageSourcePolicy, isAllowedDataImageSource } from "../src/image-policy";
import { renderMdx } from "../src/pipeline";

afterEach(() => { resetExportHTMLSession(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

function fixture(html = "<h2>First heading</h2>") {
  const root = document.createElement("main");
  root.innerHTML = html;
  const results: ExportHTMLResultPayload[] = [];
  const host: ExportHTMLHost = {
    previewRoot: root, latestRenderID: 4, documentTheme: "light",
    collectStyleText: () => "", waitForFonts: async () => {},
    postResult: (result) => results.push(result),
  };
  const payload: ExportHTMLPayload = {
    exportID: 1, renderID: 4, phase: "discovery", resourceOutcomes: [], documentTitle: null,
  };
  return { root, results, host, payload };
}

async function exportedTitle(html: string, documentTitle: string | null = null) {
  const { host, results, payload } = fixture(html);
  payload.documentTitle = documentTitle;
  await handleExportHTML(payload, host);
  await handleExportHTML({ ...payload, phase: "finalization" }, host);
  const state = results.at(-1)!.state;
  expect(state.kind).toBe("ready");
  if (state.kind !== "ready") throw new Error("Expected export");
  return new DOMParser().parseFromString(state.html, "text/html").title;
}

describe("export review regressions", () => {
  it("keeps CSS closing tags inside the style element", () => {
    const built = buildStaticExportHTML({ bodyHTML: "<p>body</p>", frozenTheme: "light",
      title: "title", styleText: '.mermaid text::after { content: "</StYlE><b>x</b>"; }' });
    if (!("html" in built)) throw new Error("Expected export");
    const doc = new DOMParser().parseFromString(built.html, "text/html");
    expect(doc.querySelector("b")).toBeNull();
    expect(doc.querySelectorAll("style")).toHaveLength(1);
    expect(doc.querySelector("style")!.textContent).toContain('\\3c /StYlE>');
    expect(doc.body.textContent!.trim()).toBe("body");
  });

  it("protects renderer-injected style nodes inside the static body too", () => {
    const { root } = fixture();
    const style = document.createElement("style");
    style.textContent = '.mermaid { content: "</style><b>injected</b>"; }';
    root.append(style);
    sanitizeStaticClone(root);
    const reparsed = new DOMParser().parseFromString(root.innerHTML, "text/html");
    expect(reparsed.querySelector("b")).toBeNull();
    expect(reparsed.querySelector("style")!.textContent).toContain("\\3c /style>");
  });

  it.each(["png", "jpeg", "gif", "webp"])("preserves inline %s images and stable resource indexes", async (mime) => {
    const src = `data:image/${mime};base64,AAAA`;
    const { root, host, results, payload } = fixture(`<img src="${src}"><img src="asset://x.png"><img src="https://example.com/x.png">`);
    expect(collectImageResources(root).map((r) => r.resourceID)).toEqual(["image-1", "image-2"]);
    const before = root.innerHTML;
    await handleExportHTML(payload, host);
    await handleExportHTML({ ...payload, phase: "finalization" }, host);
    const state = results.at(-1)!.state;
    if (state.kind !== "ready") throw new Error("Expected export");
    const doc = new DOMParser().parseFromString(state.html, "text/html");
    expect(doc.querySelector("img")!.getAttribute("src")).toBe(src);
    expect(doc.querySelectorAll("img")).toHaveLength(1);
    expect(doc.querySelectorAll(".export-image-placeholder")).toHaveLength(2);
    expect(root.innerHTML).toBe(before);
  });

  it.each(["data:image/jpg;base64,AA==", "data:image/svg+xml,<svg/>", "data:image/png;base64"])("shares the live image allowlist for %s", (src) => {
    expect(isAllowedDataImageSource(src)).toBe(false);
    expect(imageSourcePolicy(src, null, false).action).toBe("block");
    expect(collectImageResources(fixture(`<img src="${src}">`).root)).toHaveLength(1);
  });

  it.each(["waitForFonts", "collectStyleText"] as const)("posts failed if %s throws", async (callback) => {
    const { host, results, payload } = fixture();
    host[callback] = () => { throw new Error("host callback failed"); };
    await handleExportHTML(payload, host);
    await handleExportHTML({ ...payload, phase: "finalization" }, host);
    expect(results.at(-1)!.state).toEqual({ kind: "failed", reason: "serialization-failed" });
  });

  it("posts failed if cloning throws", async () => {
    const { root, host, results, payload } = fixture();
    await handleExportHTML(payload, host);
    vi.spyOn(root, "cloneNode").mockImplementation(() => { throw new Error("clone"); });
    await handleExportHTML({ ...payload, phase: "finalization" }, host);
    expect(results.at(-1)!.state.kind).toBe("failed");
  });

  it("superseded discovery leaves no live attributes and late finalization cannot clear its successor", async () => {
    const { root, host, results, payload } = fixture('<img src="asset://x.png">');
    const before = root.innerHTML;
    await handleExportHTML(payload, host);
    const newer = { ...payload, exportID: 2 };
    await handleExportHTML(newer, host);
    await handleExportHTML({ ...payload, phase: "finalization" }, host);
    await handleExportHTML({ ...newer, phase: "finalization" }, host);
    expect(results.map((r) => r.state.kind)).toEqual(["resourcesNeeded", "resourcesNeeded", "failed", "ready"]);
    expect(root.innerHTML).toBe(before);
    expect(root.querySelector("[data-export-resource-id]")).toBeNull();
  });

  it.each(["fonts", "styles"])("render reset invalidates a finalization awaiting %s", async (boundary) => {
    const { host, results, payload } = fixture();
    let release!: () => void;
    const blocked = new Promise<void>((resolve) => { release = resolve; });
    if (boundary === "fonts") host.waitForFonts = () => blocked;
    else host.collectStyleText = async () => { await blocked; return ""; };
    await handleExportHTML(payload, host);
    const finalization = handleExportHTML({ ...payload, phase: "finalization" }, host);
    await Promise.resolve();
    resetExportHTMLSession();
    release();
    await finalization;
    expect(results.at(-1)!.state).toEqual({ kind: "failed", reason: "superseded" });
  });

  it("collects loaded CSS without any fetch", () => {
    const fetch = vi.fn(() => { throw new Error("CSP forbids fetch"); });
    vi.stubGlobal("fetch", fetch);
    const doc = document;
    const previous = doc.head.innerHTML;
    doc.head.innerHTML = '<link rel="stylesheet" href="bundle.css"><style>.loaded { color: red; }</style>';
    expect(collectPreviewStyleText(doc)).toContain(".loaded");
    expect(fetch).not.toHaveBeenCalled();
    doc.head.innerHTML = previous;
  });

  it("chooses frontmatter, otherwise the first document heading of any level, otherwise Untitled", async () => {
    expect(await exportedTitle("<p>intro</p><h2>First</h2><h1>Later</h1>")).toBe("First");
    expect(await exportedTitle("<h2>Heading</h2>", "A <title> & text")).toBe("A <title> & text");
    expect(await exportedTitle("<p>No heading</p>")).toBe("Untitled");
  });

  it("ignores component-card headings before the actual MDX document heading", async () => {
    const html = await renderMdx('<Card>\n\n# Card heading\n\n</Card>\n\n## Document heading');
    expect(html).toContain("mdx-component-card");
    expect(await exportedTitle(html)).toBe("Document heading");
  });
});
